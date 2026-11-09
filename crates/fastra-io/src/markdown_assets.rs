//! Neue Markdown-Bilddateien mit expliziter Vorschau; bestehende Dateien bleiben unangetastet.
use super::*;

const MAX_FILES: usize = 32;
const MAX_FILE_BYTES: usize = 32 * 1024 * 1024;
const MAX_TOTAL_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Owner {
    pub document: String,
    pub revision: u64,
    pub generation: u64,
}
#[derive(Clone, Debug)]
pub struct Input {
    pub extension: String,
    pub bytes: Arc<Vec<u8>>,
}
#[derive(Clone, Debug)]
pub struct Preview {
    pub relative: PathBuf,
    pub bytes: usize,
    pub sha256: String,
}
pub struct Plan {
    owner: Owner,
    target: save_target::Target,
    parent: Arc<Directory>,
    images: Option<Arc<Directory>>,
    inputs: Vec<Input>,
    preview: Vec<Preview>,
}
pub struct Receipt {
    document: String,
    parent: Arc<Directory>,
    images: Option<Arc<Directory>>,
    inputs: Vec<Input>,
    preview: Vec<Preview>,
    entries: Vec<Asset>,
    recovery_required: bool,
    applied: bool,
}
struct Asset {
    original: OsString,
    claim: Option<OsString>,
    snapshot: Snapshot,
}
fn exists(directory: &Directory, entry: &OsStr) -> Result<bool> {
    let entry = name(entry)?;
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe {
        libc::fstatat(
            directory.file.as_raw_fd(),
            entry.as_ptr(),
            &mut info,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0
    {
        return Ok(true);
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ENOENT) {
        Ok(false)
    } else {
        Err(error.into())
    }
}
fn rename(directory: &Directory, from: &OsStr, to: &OsStr) -> Result<()> {
    let (from, to) = (name(from)?, name(to)?);
    syscall(unsafe {
        libc::renameat2(
            directory.file.as_raw_fd(),
            from.as_ptr(),
            directory.file.as_raw_fd(),
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    })?;
    Ok(())
}
fn short_name(mut value: usize) -> String {
    let mut output = Vec::new();
    while value > 0 {
        output.push(b"0123456789abcdefghijklmnopqrstuvwxyz"[value % 36] as char);
        value /= 36;
    }
    output.iter().rev().collect()
}
pub(super) fn remove_temporary(directory: &Directory, entry: &OsStr, file: &File) -> Result<()> {
    if !exists(directory, entry)? {
        return Ok(());
    }
    let expected = file.metadata()?;
    let claim = random_name(".fastra-image-cleanup-")?;
    let observed = directory.regular(entry)?.metadata()?;
    if (observed.dev(), observed.ino()) != (expected.dev(), expected.ino()) {
        return Err(Error::Stale);
    }
    rename(directory, entry, &claim)?;
    let moved = directory.regular(&claim)?.metadata()?;
    if (moved.dev(), moved.ino()) != (expected.dev(), expected.ino()) {
        let _ = rename(directory, &claim, entry);
        return Err(Error::RecoveryRequired(directory.path.clone()));
    }
    directory.remove(&claim, false)
}
fn create_images(parent: &Arc<Directory>) -> Result<Arc<Directory>> {
    parent.bound()?;
    let temporary = random_name(".fastra-image-directory-")?;
    let encoded = name(&temporary)?;
    syscall(unsafe { libc::mkdirat(parent.file.as_raw_fd(), encoded.as_ptr(), 0o755) })?;
    let result = (|| {
        let file = owned_file(unsafe {
            libc::openat(
                parent.file.as_raw_fd(),
                encoded.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let meta = file.metadata()?;
        let identity = [meta.dev(), meta.ino()];
        if identity[0] != parent.identity[0] {
            return Err(Error::Stale);
        }
        parent.bound()?;
        rename(parent, &temporary, OsStr::new("images"))?;
        let images = Arc::new(Directory {
            file,
            path: parent.path.join("images"),
            identity,
        });
        images.bound()?;
        parent.sync()?;
        Ok(images)
    })();
    if result.is_err() {
        let _ = parent.remove(&temporary, true);
    }
    result
}
#[cfg(test)]
type RaceHook = Box<dyn FnMut(&str, &Path)>;
#[cfg(test)]
thread_local! { static RACE:std::cell::RefCell<Option<RaceHook>> = const{std::cell::RefCell::new(None)}; }
#[cfg(test)]
thread_local! {static FAIL_IDENTITY:std::cell::Cell<bool>=const{std::cell::Cell::new(false)}; static FAIL_UNDO_SYNC:std::cell::Cell<bool>=const{std::cell::Cell::new(false)};}
fn sync_undo(directory: &Directory) -> Result<()> {
    #[cfg(test)]
    if FAIL_UNDO_SYNC.with(|flag| flag.replace(false)) {
        return Err(std::io::Error::from_raw_os_error(libc::EIO).into());
    }
    directory.sync()
}
fn checkpoint(phase: &str, path: &Path) {
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
impl Plan {
    pub fn prepare(
        document: &Path,
        owner: Owner,
        inputs: Vec<Input>,
        cancel: &Cancellation,
    ) -> Result<Self> {
        let document = Snapshot::read_bounded(document, 32 * 1024 * 1024, cancel)?;
        Self::prepare_at(save_target::Target::from_snapshot(document)?, owner, inputs, cancel)
    }
    pub fn prepare_at(
        target: save_target::Target,
        owner: Owner,
        inputs: Vec<Input>,
        cancel: &Cancellation,
    ) -> Result<Self> {
        if inputs.is_empty()
            || inputs.len() > MAX_FILES
            || owner.document.is_empty()
            || owner.document.len() > 256
        {
            return Err(Error::Limit);
        }
        let mut total = 0usize;
        for input in &inputs {
            total = total.checked_add(input.bytes.len()).ok_or(Error::Limit)?;
            if input.bytes.is_empty()
                || input.bytes.len() > MAX_FILE_BYTES
                || total > MAX_TOTAL_BYTES
                || input.extension.is_empty()
                || input.extension.len() > 8
                || !input
                    .extension
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            {
                return Err(Error::Limit);
            }
        }
        target.verify(cancel)?;
        let parent = target.parent.clone();
        parent.supported()?;
        let images = if exists(&parent, OsStr::new("images"))? {
            let directory = Arc::new(Directory::open(&parent.path.join("images"))?);
            if directory.identity[0] != parent.identity[0] {
                return Err(Error::UnsupportedFilesystem);
            }
            Some(directory)
        } else {
            None
        };
        let mut preview = Vec::new();
        let mut counter = 1;
        for input in &inputs {
            loop {
                cancel.check()?;
                if counter >= 10000 {
                    return Err(Error::Limit);
                }
                let file = format!("{}.{}", short_name(counter), input.extension);
                counter += 1;
                if match images.as_ref() {
                    Some(dir) => exists(dir, OsStr::new(&file))?,
                    None => false,
                } {
                    continue;
                }
                preview.push(Preview {
                    relative: PathBuf::from("images").join(file),
                    bytes: input.bytes.len(),
                    sha256: format!("{:x}", Sha256::digest(input.bytes.as_slice())),
                });
                break;
            }
        }
        Ok(Self {
            owner,
            target,
            parent,
            images,
            inputs,
            preview,
        })
    }
    pub fn preview(&self) -> &[Preview] {
        &self.preview
    }
    pub fn owner(&self) -> &Owner {
        &self.owner
    }
    pub fn apply(self, current: &Owner, cancel: &Cancellation) -> Result<Receipt> {
        if *current != self.owner {
            return Err(Error::Stale);
        }
        self.target.verify(cancel)?;
        self.parent.bound()?;
        let images = match self.images {
            Some(images) => {
                images.bound()?;
                images
            }
            None => create_images(&self.parent)?,
        };
        let mut receipt = Receipt {
            document: self.owner.document,
            parent: self.parent,
            images: Some(images),
            inputs: self.inputs,
            preview: self.preview,
            entries: Vec::new(),
            recovery_required: false,
            applied: true,
        };
        if let Err(error) = receipt.publish(cancel) {
            if receipt.remove_current(&Cancellation::default()).is_err() {
                return Err(Error::RecoveryRequired(receipt.parent.path.join("images")));
            }
            if !receipt.entries.is_empty() {
                return Err(Error::RecoveryRequired(receipt.parent.path.join("images")));
            }
            return Err(error);
        }
        Ok(receipt)
    }
}
impl Receipt {
    pub fn preview(&self) -> &[Preview] {
        &self.preview
    }
    pub fn is_applied(&self) -> bool {
        self.applied
    }
    fn bound(&self) -> Result<Arc<Directory>> {
        self.parent.bound()?;
        let images = self.images.clone().ok_or(Error::Stale)?;
        images.bound()?;
        Ok(images)
    }
    fn publish(&mut self, cancel: &Cancellation) -> Result<()> {
        let images = self.bound()?;
        for entry in &self.preview {
            if exists(
                &images,
                entry.relative.file_name().ok_or(Error::InvalidPath)?,
            )? {
                return Err(Error::Stale);
            }
        }
        for (entry, input) in self.preview.iter().zip(&self.inputs) {
            cancel.check()?;
            images.bound()?;
            let temporary = random_name(".fastra-image-")?;
            let target = entry.relative.file_name().ok_or(Error::InvalidPath)?;
            let mut file = images.create(&temporary, 0o600)?;
            let result = (|| {
                for chunk in input.bytes.chunks(65536) {
                    cancel.check()?;
                    file.write_all(chunk)?;
                }
                file.sync_all()?;
                checkpoint("before-temp-hash", &images.path.join(&temporary));
                use std::io::{Seek, SeekFrom};
                file.seek(SeekFrom::Start(0))?;
                let (actual, expected) = read_file(file.try_clone()?, cancel, MAX_FILE_BYTES)?;
                if actual.as_slice() != input.bytes.as_slice()
                    || expected.digest != <[u8; 32]>::from(Sha256::digest(input.bytes.as_slice()))
                {
                    return Err(Error::RecoveryRequired(images.path.join(&temporary)));
                }
                if fingerprint(&images, &temporary, cancel)? != expected {
                    return Err(Error::RecoveryRequired(images.path.join(&temporary)));
                }
                images.bound()?;
                checkpoint("before-publish", &images.path.join(target));
                cancel.check()?;
                rename(&images, &temporary, target)?;
                let snapshot = Snapshot {
                    parent: images.clone(),
                    name: target.to_owned(),
                    bytes: input.bytes.clone(),
                    fingerprint: expected,
                };
                // Auch bei fehlgeschlagenem Postflight bleibt die eigene veröffentlichte Datei als Receipt bekannt.
                self.entries.push(Asset {
                    original: target.to_owned(),
                    claim: None,
                    snapshot,
                });
                images.sync()?;
                images.bound()?;
                self.entries.last().unwrap().snapshot.verify(cancel)
            })();
            if matches!(result, Err(Error::RecoveryRequired(_))) {
                return result;
            }
            if remove_temporary(&images, &temporary, &file).is_err() {
                return Err(Error::RecoveryRequired(images.path.clone()));
            }
            result?;
        }
        Ok(())
    }
    fn identity(&self, index: usize) -> Result<()> {
        #[cfg(test)]
        if FAIL_IDENTITY.with(|flag| flag.replace(false)) {
            return Err(std::io::Error::from_raw_os_error(libc::EIO).into());
        }
        let snapshot = &self.entries[index].snapshot;
        let info = snapshot.parent.regular(&snapshot.name)?.metadata()?;
        if (info.dev(), info.ino()) != (snapshot.fingerprint.device, snapshot.fingerprint.inode) {
            return Err(Error::RecoveryRequired(snapshot.path()));
        }
        Ok(())
    }
    fn relocate(&mut self, index: usize, destination: &OsStr) -> Result<()> {
        checkpoint("before-relocate", &self.entries[index].snapshot.path());
        self.identity(index)?;
        let snapshot = &mut self.entries[index].snapshot;
        rename(&snapshot.parent, &snapshot.name, destination)?;
        // Der Ledger folgt jedem erfolgreichen Rename vor dem nächsten falliblen Schritt.
        snapshot.name = destination.to_owned();
        self.identity(index)
    }
    fn transition(
        &mut self,
        retained: bool,
        verify_bytes: bool,
        cancel: &Cancellation,
    ) -> Result<()> {
        let images = self.bound()?;
        if self.recovery_required {
            return Err(Error::RecoveryRequired(images.path.clone()));
        }
        let original = self
            .entries
            .iter()
            .map(|asset| asset.snapshot.name.clone())
            .collect::<Vec<_>>();
        let mut destination = Vec::new();
        for (index, asset) in self.entries.iter().enumerate() {
            if verify_bytes {
                asset.snapshot.verify(cancel)?;
            } else {
                self.identity(index)?;
            }
            let target = if retained {
                match &asset.claim {
                    Some(claim) => claim.clone(),
                    None => random_name(&format!(
                        ".fastra-image-undo-{}-",
                        asset.original.to_str().ok_or(Error::InvalidPath)?
                    ))?,
                }
            } else {
                asset.original.clone()
            };
            if exists(&images, &target)? {
                return Err(Error::Stale);
            }
            destination.push(target);
        }
        let result = (|| {
            for (index, target) in destination.iter().enumerate() {
                cancel.check()?;
                images.bound()?;
                if verify_bytes {
                    self.entries[index].snapshot.verify(cancel)?;
                }
                self.relocate(index, target)?;
                if retained {
                    self.entries[index].claim = Some(target.clone());
                }
                checkpoint(
                    if retained {
                        "after-claim"
                    } else if verify_bytes {
                        "after-redo"
                    } else {
                        "after-rollback-undo"
                    },
                    &self.entries[index].snapshot.path(),
                );
                if verify_bytes {
                    self.entries[index].snapshot.verify(cancel)?;
                } else {
                    self.identity(index)?;
                }
            }
            images.bound()?;
            if verify_bytes {
                for asset in &self.entries {
                    asset.snapshot.verify(cancel)?;
                }
            }
            if retained {
                sync_undo(&images)
            } else {
                images.sync()
            }
        })();
        if let Err(error) = result {
            let mut recovered = true;
            for (index, previous) in original.iter().enumerate().rev() {
                if self.entries[index].snapshot.name != *previous {
                    recovered &= self.relocate(index, previous).is_ok();
                }
            }
            self.recovery_required = !recovered;
            return if recovered {
                Err(error)
            } else {
                Err(Error::RecoveryRequired(images.path.clone()))
            };
        }
        self.applied = !retained;
        Ok(())
    }
    fn remove_current(&mut self, cancel: &Cancellation) -> Result<()> {
        self.transition(true, true, cancel)
    }
    /// Der Host bindet jeden Aufruf zusätzlich an seine aktuelle Revision/Generation und prüft diese nach I/O erneut.
    pub fn undo(&mut self, current: &Owner, cancel: &Cancellation) -> Result<()> {
        if current.document != self.document || !self.applied {
            return Err(Error::Stale);
        }
        self.remove_current(cancel)
    }
    /// Erhaltene Inodes werden exklusiv zurückbenannt; Änderungen bleiben als Recoverydateien erhalten.
    pub fn redo(&mut self, current: &Owner, cancel: &Cancellation) -> Result<()> {
        if current.document != self.document || self.applied {
            return Err(Error::Stale);
        }
        self.transition(false, true, cancel)
            .map_err(|error| match error {
                Error::Stale
                    if self
                        .entries
                        .iter()
                        .any(|asset| asset.snapshot.verify(cancel).is_err()) =>
                {
                    Error::RecoveryRequired(self.parent.path.join("images"))
                }
                other => other,
            })
    }
    /// Nur Rücknahme eines noch nicht vom Host angenommenen Undo: erhaltene Inodes dürfen dabei ihre Fremdänderungen behalten.
    pub fn rollback_undo(&mut self, current: &Owner) -> Result<()> {
        if current.document != self.document || self.applied {
            return Err(Error::Stale);
        }
        self.transition(false, false, &Cancellation::default())
    }
    pub fn recovery_paths(&self) -> Vec<(PathBuf, PathBuf)> {
        self.entries
            .iter()
            .filter(|asset| self.recovery_required || asset.snapshot.name != asset.original)
            .map(|asset| {
                (
                    asset.snapshot.parent.path.join(&asset.original),
                    asset.snapshot.path(),
                )
            })
            .collect()
    }
}
#[cfg(test)]
#[path = "markdown_assets/tests.rs"]
mod tests;
