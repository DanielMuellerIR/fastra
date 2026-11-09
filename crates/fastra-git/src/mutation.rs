//! Freigegebene Indexänderungen; Git erzeugt das Indexformat, Fastra publiziert nur geprüfte Bytes.
use crate::*;
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    },
};

const MAX_INDEX: usize = 32 * 1024 * 1024;
const MAX_FILES: usize = 128;
const MAX_FILE: usize = 32 * 1024 * 1024;
const MAX_TOTAL: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexAction {
    Stage,
    Unstage,
}

pub struct IndexPreview {
    action: IndexAction,
    repository: Repository,
    paths: Vec<RepoPath>,
    head: Head,
    index: Option<Blob>,
    files: Vec<ObservedFile>,
    prepared: Vec<u8>,
    diff: GitOutput,
    operation_output: GitOutput,
    before_tree: String,
    after_tree: String,
}
impl std::fmt::Debug for IndexPreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IndexPreview")
            .field("action", &self.action)
            .field("paths", &self.paths)
            .field("prepared_index_bytes", &self.prepared.len())
            .finish_non_exhaustive()
    }
}
impl IndexPreview {
    pub fn action(&self) -> IndexAction {
        self.action
    }
    pub fn paths(&self) -> &[RepoPath] {
        &self.paths
    }
    pub fn branch(&self) -> Option<&[u8]> {
        self.head.branch.as_deref()
    }
    pub fn head_oid(&self) -> Option<&[u8]> {
        self.head.oid.as_deref()
    }
    pub fn operation_output(&self) -> &GitOutput {
        &self.operation_output
    }
    pub fn diff(&self) -> &GitOutput {
        &self.diff
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Head {
    branch: Option<Vec<u8>>,
    oid: Option<Vec<u8>>,
    raw: Vec<u8>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    length: u64,
    mode: u32,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl Stamp {
    fn new(m: &fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            length: m.len(),
            mode: m.mode(),
            mtime: m.mtime(),
            mtime_ns: m.mtime_nsec(),
            ctime: m.ctime(),
            ctime_ns: m.ctime_nsec(),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Blob {
    stamp: Stamp,
    bytes: Vec<u8>,
}
fn io(e: std::io::Error) -> Error {
    Error::Io(e.to_string())
}
fn cancelled(cancellation: &Cancellation) -> Result<(), Error> {
    if cancellation.is_cancelled() {
        Err(Error::Cancelled(GitOutput::empty()))
    } else {
        Ok(())
    }
}
fn regular(mut file: File, limit: usize, cancellation: &Cancellation) -> Result<Blob, Error> {
    cancelled(cancellation)?;
    let before = file.metadata().map_err(io)?;
    if !before.is_file() {
        return Err(Error::InvalidInput("only regular files are supported"));
    }
    if before.len() > limit as u64 {
        return Err(Error::InvalidInput("index preview size limit"));
    }
    let mut bytes = Vec::with_capacity(before.len() as usize);
    let mut block = [0u8; 65536];
    loop {
        cancelled(cancellation)?;
        let n = file.read(&mut block).map_err(io)?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > limit {
            return Err(Error::InvalidInput("index preview size limit"));
        }
        bytes.extend_from_slice(&block[..n]);
    }
    let stamp = Stamp::new(&before);
    if stamp != Stamp::new(&file.metadata().map_err(io)?) {
        return Err(Error::StalePreview);
    }
    Ok(Blob { stamp, bytes })
}
#[derive(Debug, Clone)]
struct Ancestor {
    directory: std::sync::Arc<File>,
    stamp: Stamp,
}
// Frisch geöffnete Deskriptoren derselben Verzeichnisidentität müssen vergleichbar bleiben.
impl PartialEq for Ancestor {
    fn eq(&self, other: &Self) -> bool {
        self.stamp == other.stamp
    }
}
impl Eq for Ancestor {}
type AncestryCache = std::collections::HashMap<(u64, u64), std::sync::Weak<File>>;
const MAX_ANCESTORS: usize = 256;
const MAX_DEPTH: usize = 64;
fn hold_directory(file: File, cache: &mut AncestryCache) -> Result<Ancestor, Error> {
    let metadata = file.metadata().map_err(io)?;
    if !metadata.is_dir() {
        return Err(Error::StalePreview);
    }
    let stamp = Stamp::new(&metadata);
    let identity = (stamp.dev, stamp.ino);
    let directory = if let Some(existing) = cache.get(&identity).and_then(std::sync::Weak::upgrade)
    {
        existing
    } else {
        cache.retain(|_, file| file.strong_count() > 0);
        if cache.len() >= MAX_ANCESTORS {
            return Err(Error::InvalidInput(
                "directory ancestry exceeds 256 open descriptors",
            ));
        }
        let file = std::sync::Arc::new(file);
        cache.insert(identity, std::sync::Arc::downgrade(&file));
        file
    };
    Ok(Ancestor { directory, stamp })
}
#[derive(Debug, Clone, PartialEq, Eq)]
enum FileState {
    Missing,
    Regular(Blob),
    Symlink { stamp: Stamp, target: Vec<u8> },
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct ObservedFile {
    ancestry: Vec<Ancestor>,
    state: FileState,
}
impl ObservedFile {
    fn verify_ancestry(&self, cancellation: &Cancellation) -> Result<(), Error> {
        for ancestor in &self.ancestry {
            cancelled(cancellation)?;
            if Stamp::new(&ancestor.directory.metadata().map_err(io)?) != ancestor.stamp {
                return Err(Error::StalePreview);
            }
        }
        Ok(())
    }
}
// Die Unix-ABI verwendet unterschiedliche Ganzzahltypen für stat-Felder.
#[allow(clippy::unnecessary_cast)]
fn stamp_at(directory: &File, name: &CString) -> Result<Option<Stamp>, Error> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(io(error));
    }
    let stat = unsafe { stat.assume_init() };
    Ok(Some(Stamp {
        dev: stat.st_dev as u64,
        ino: stat.st_ino as u64,
        length: stat.st_size as u64,
        mode: stat.st_mode as u32,
        mtime: stat.st_mtime as i64,
        mtime_ns: stat.st_mtime_nsec as i64,
        ctime: stat.st_ctime as i64,
        ctime_ns: stat.st_ctime_nsec as i64,
    }))
}
#[allow(clippy::unnecessary_cast)]
fn observe(
    repository: &Repository,
    path: &RepoPath,
    cancellation: &Cancellation,
    cache: &mut AncestryCache,
) -> Result<ObservedFile, Error> {
    cancelled(cancellation)?;
    let relative = PathBuf::from(path.argument());
    let parts: Vec<_> = relative.components().collect();
    if parts.len() > MAX_DEPTH {
        return Err(Error::InvalidInput(
            "directory ancestry exceeds 64 components",
        ));
    }
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&repository.root)
        .map_err(io)?;
    let root = hold_directory(root, cache)?;
    if (root.stamp.dev, root.stamp.ino) != repository.root_identity {
        return Err(Error::StaleRepository);
    }
    let mut ancestry = vec![root];
    for part in &parts[..parts.len() - 1] {
        cancelled(cancellation)?;
        let name = CString::new(part.as_os_str().as_bytes()).unwrap();
        let parent = ancestry.last().unwrap().directory.as_raw_fd();
        let fd = unsafe {
            libc::openat(
                parent,
                name.as_ptr(),
                libc::O_RDONLY
                    | libc::O_DIRECTORY
                    | libc::O_NOFOLLOW
                    | libc::O_NONBLOCK
                    | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                let observed = ObservedFile {
                    ancestry,
                    state: FileState::Missing,
                };
                observed.verify_ancestry(cancellation)?;
                return Ok(observed);
            }
            if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
                return Err(Error::InvalidInput(
                    "path traverses a symlink or non-directory",
                ));
            }
            return Err(io(error));
        }
        ancestry.push(hold_directory(unsafe { File::from_raw_fd(fd) }, cache)?);
    }
    let parent = &ancestry.last().unwrap().directory;
    let name = CString::new(parts.last().unwrap().as_os_str().as_bytes()).unwrap();
    let before = stamp_at(parent, &name)?;
    let state = match before.as_ref() {
        None => FileState::Missing,
        Some(stamp) if stamp.mode & libc::S_IFMT as u32 == libc::S_IFLNK as u32 => {
            let mut target = vec![0u8; 4097];
            let size = unsafe {
                libc::readlinkat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    target.as_mut_ptr().cast(),
                    target.len(),
                )
            };
            if size < 0 {
                return Err(io(std::io::Error::last_os_error()));
            }
            if size > 4096 {
                return Err(Error::InvalidInput("symlink target exceeds 4096 bytes"));
            }
            target.truncate(size as usize);
            FileState::Symlink {
                stamp: stamp.clone(),
                target,
            }
        }
        Some(stamp) if stamp.mode & libc::S_IFMT as u32 == libc::S_IFREG as u32 => {
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(io(std::io::Error::last_os_error()));
            }
            let blob = regular(unsafe { File::from_raw_fd(fd) }, MAX_FILE, cancellation)?;
            if &blob.stamp != stamp {
                return Err(Error::StalePreview);
            }
            FileState::Regular(blob)
        }
        Some(_) => {
            return Err(Error::InvalidInput(
                "directories, submodules and special files cannot be staged here",
            ))
        }
    };
    if stamp_at(parent, &name)? != before {
        return Err(Error::StalePreview);
    }
    let observed = ObservedFile { ancestry, state };
    observed.verify_ancestry(cancellation)?;
    Ok(observed)
}
fn directory(repo: &Repository) -> Result<File, Error> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&repo.git_dir)
        .map_err(io)?;
    let m = file.metadata().map_err(io)?;
    if (m.dev(), m.ino()) != repo.git_identity {
        return Err(Error::StaleRepository);
    }
    Ok(file)
}
fn open_at(dir: &File, name: &str, flags: i32, mode: u32) -> Result<File, Error> {
    let name = CString::new(name).unwrap();
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            mode,
        )
    };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        if flags & libc::O_EXCL != 0 && error.kind() == std::io::ErrorKind::AlreadyExists {
            return Err(Error::IndexLocked);
        }
        return Err(io(error));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn index(dir: &File, cancellation: &Cancellation) -> Result<Option<Blob>, Error> {
    let name = c"index";
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(io(e));
    }
    regular(unsafe { File::from_raw_fd(fd) }, MAX_INDEX, cancellation).map(Some)
}
struct IndexLock {
    directory: File,
    file: File,
    live: bool,
}
impl IndexLock {
    fn acquire(directory: File) -> Result<Self, Error> {
        let file = open_at(
            &directory,
            "index.lock",
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o666,
        )?;
        Ok(Self {
            directory,
            file,
            live: true,
        })
    }
    // dev_t unterscheidet sich zwischen Unix-Plattformen.
    #[allow(clippy::unnecessary_cast)]
    fn own_name(&self) -> Result<(), Error> {
        let mut named = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.directory.as_raw_fd(),
                c"index.lock".as_ptr(),
                named.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io(std::io::Error::last_os_error()));
        }
        let named = unsafe { named.assume_init() };
        let owned = self.file.metadata().map_err(io)?;
        if named.st_dev as u64 != owned.dev() || named.st_ino as u64 != owned.ino() {
            return Err(Error::StalePreview);
        }
        Ok(())
    }
    fn publish(
        mut self,
        bytes: &[u8],
        mode: Option<u32>,
        cancellation: &Cancellation,
        validate: impl FnOnce(&File) -> Result<(), Error>,
    ) -> Result<(), Error> {
        self.own_name()?;
        for chunk in bytes.chunks(65536) {
            cancelled(cancellation)?;
            self.file.write_all(chunk).map_err(io)?;
        }
        if let Some(mode) = mode {
            if unsafe { libc::fchmod(self.file.as_raw_fd(), (mode & 0o777) as libc::mode_t) } != 0 {
                return Err(io(std::io::Error::last_os_error()));
            }
        }
        self.file.sync_all().map_err(io)?;
        validate(&self.directory)?;
        cancelled(cancellation)?;
        self.own_name()?;
        if unsafe {
            libc::renameat(
                self.directory.as_raw_fd(),
                c"index.lock".as_ptr(),
                self.directory.as_raw_fd(),
                c"index".as_ptr(),
            )
        } != 0
        {
            return Err(io(std::io::Error::last_os_error()));
        }
        self.live = false;
        self.directory
            .sync_all()
            .map_err(|e| Error::IndexPublished(e.to_string()))
    }
}
impl Drop for IndexLock {
    fn drop(&mut self) {
        if self.live && self.own_name().is_ok() {
            unsafe { libc::unlinkat(self.directory.as_raw_fd(), c"index.lock".as_ptr(), 0) };
        }
    }
}
impl Repository {
    pub fn index_status(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<ReadResult<Status>, Error> {
        self.verify(policy, cancellation)?;
        self.check_stage_extensions(policy, cancellation)?;
        index(&directory(self)?, cancellation)?;
        self.status(policy, cancellation)
    }
    fn check_stage_extensions(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<(), Error> {
        let config = self.git.checked(
            &self.root,
            &[
                "config".into(),
                "--name-only".into(),
                "--get-regexp".into(),
                r"^filter\..*\.(clean|process)$".into(),
            ],
            policy,
            cancellation,
        );
        match config {
            Ok(_) => {
                return Err(Error::InvalidInput(
                    "external clean/process filters require the Git CLI",
                ))
            }
            Err(Error::GitFailed(output))
                if output.exit_code == Some(1) && output.stderr.is_empty() => {}
            Err(e) => return Err(e),
        }
        let configured = self.git.checked(
            &self.root,
            &[
                "config".into(),
                "--path".into(),
                "--get".into(),
                "core.hooksPath".into(),
            ],
            policy,
            cancellation,
        );
        let hooks = match configured {
            Ok(out) => {
                let bytes = out
                    .stdout
                    .strip_suffix(b"\n")
                    .ok_or(Error::MalformedOutput("hook path terminator"))?;
                if bytes.contains(&0) {
                    return Err(Error::MalformedOutput("hook path"));
                }
                let path = PathBuf::from(OsString::from_vec(bytes.to_vec()));
                if path.is_absolute() {
                    path
                } else {
                    self.root.join(path)
                }
            }
            Err(Error::GitFailed(output))
                if output.exit_code == Some(1) && output.stderr.is_empty() =>
            {
                let common = self.git.checked(
                    &self.root,
                    &[
                        "rev-parse".into(),
                        "--path-format=absolute".into(),
                        "--git-common-dir".into(),
                    ],
                    policy,
                    cancellation,
                )?;
                output_path(&common.stdout)?.join("hooks")
            }
            Err(e) => return Err(e),
        };
        match fs::metadata(hooks.join("post-index-change")) {
            Ok(m) if m.is_file() && m.mode() & 0o111 != 0 => {
                return Err(Error::InvalidInput(
                    "post-index-change hook requires the Git CLI",
                ))
            }
            Ok(_) => {}
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) => {}
            Err(e) => return Err(io(e)),
        }
        Ok(())
    }
    fn mutation_head(&self, policy: Policy, cancellation: &Cancellation) -> Result<Head, Error> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.git_dir.join("HEAD"))
            .map_err(io)?;
        let raw = regular(file, 4096, cancellation)?.bytes;
        let branch = match self.git.checked(
            &self.root,
            &["symbolic-ref".into(), "-q".into(), "HEAD".into()],
            policy,
            cancellation,
        ) {
            Ok(out) => {
                let full = out
                    .stdout
                    .strip_suffix(b"\n")
                    .ok_or(Error::MalformedOutput("branch terminator"))?;
                full.strip_prefix(b"refs/heads/")
                    .ok_or(Error::InvalidInput(
                        "index mutation requires a current branch",
                    ))?
                    .to_vec()
            }
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) => {
                return Err(Error::InvalidInput(
                    "index mutation requires a current branch",
                ))
            }
            Err(e) => return Err(e),
        };
        let oid = match self.git.checked(
            &self.root,
            &[
                "rev-parse".into(),
                "--verify".into(),
                "--quiet".into(),
                "HEAD".into(),
            ],
            policy,
            cancellation,
        ) {
            Ok(out) => {
                let value = out
                    .stdout
                    .strip_suffix(b"\n")
                    .ok_or(Error::MalformedOutput("HEAD terminator"))?;
                check_oid(value)?;
                Some(value.to_vec())
            }
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) && out.stderr.is_empty() => None,
            Err(e) => return Err(e),
        };
        Ok(Head {
            branch: Some(branch),
            oid,
            raw,
        })
    }
    /// Die Vorbereitung ändert den echten Index nicht; Git darf dabei neue lose Objekte erzeugen.
    pub fn prepare_index(
        &self,
        action: IndexAction,
        paths: &[RepoPath],
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<IndexPreview, Error> {
        let policy = Policy {
            stdout_bytes: policy.stdout_bytes.min(2 * 1024 * 1024),
            stderr_bytes: policy.stderr_bytes.min(512 * 1024),
            ..policy
        };
        self.verify(policy, cancellation)?;
        if paths.is_empty() || paths.len() > MAX_FILES {
            return Err(Error::InvalidInput("select 1 to 128 changed files"));
        }
        self.check_stage_extensions(policy, cancellation)?;
        let dir = directory(self)?;
        let original = index(&dir, cancellation)?;
        let status = self.status(policy, cancellation)?.value;
        if status
            .changes
            .iter()
            .any(|change| matches!(change.kind, ChangeKind::Unmerged))
        {
            return Err(Error::InvalidInput(
                "resolve index conflicts with Git before staging here",
            ));
        }
        let head = self.mutation_head(policy, cancellation)?;
        let mut selected = Vec::new();
        for path in paths {
            let change = status
                .changes
                .iter()
                .find(|x| x.path == *path)
                .ok_or(Error::StalePreview)?;
            if matches!(change.kind, ChangeKind::Ignored) {
                return Err(Error::InvalidInput("ignored paths are not stageable here"));
            }
            if !selected.contains(path) {
                selected.push(path.clone());
            }
            if let ChangeKind::RenameOrCopy { original, .. } = &change.kind {
                if !selected.contains(original) {
                    selected.push(original.clone());
                }
            }
        }
        if selected.len() > MAX_FILES {
            return Err(Error::InvalidInput(
                "expanded rename selection exceeds 128 paths",
            ));
        }
        let mut files = Vec::new();
        let mut ancestry_cache = AncestryCache::default();
        let mut total = 0usize;
        for path in &selected {
            let observed = observe(self, path, cancellation, &mut ancestry_cache)?;
            if let FileState::Regular(blob) = &observed.state {
                total += blob.bytes.len();
            }
            if total > MAX_TOTAL {
                return Err(Error::InvalidInput("selected file bytes exceed 64 MiB"));
            }
            files.push(observed);
        }
        let temp = tempfile::Builder::new()
            .prefix("fastra-index-")
            .tempdir_in(&self.git_dir)
            .map_err(io)?;
        let private = temp.path().join("index");
        if let Some(blob) = &original {
            fs::write(&private, &blob.bytes).map_err(io)?;
        }
        let env = [(OsString::from("GIT_INDEX_FILE"), private.into_os_string())];
        let run = |args: &[OsString]| {
            self.git
                .checked_env(&self.root, args, policy, cancellation, &env)
        };
        if original.is_none() {
            run(&["read-tree".into(), "--empty".into()])?;
        }
        let before = run(&["write-tree".into()])?.stdout;
        let before = std::str::from_utf8(&before)
            .map_err(|_| Error::MalformedOutput("invalid tree ID"))?
            .trim()
            .to_owned();
        check_oid(before.as_bytes())?;
        let mut arguments: Vec<OsString> = match action {
            IndexAction::Stage => vec!["add".into()],
            IndexAction::Unstage => {
                if let Some(oid) = head.oid.as_ref() {
                    vec![
                        "restore".into(),
                        "--staged".into(),
                        format!("--source={}", std::str::from_utf8(oid).unwrap()).into(),
                    ]
                } else {
                    vec![
                        "rm".into(),
                        "--cached".into(),
                        "--ignore-unmatch".into(),
                        "-f".into(),
                    ]
                }
            }
        };
        arguments.push("--".into());
        arguments.extend(selected.iter().map(RepoPath::argument));
        for file in &files {
            file.verify_ancestry(cancellation)?;
        }
        let operation_output = run(&arguments)?;
        for file in &files {
            file.verify_ancestry(cancellation)?;
        }
        // Ein unabhängiger Index enthält keine externen Shared-Index-Verweise.
        run(&[
            "update-index".into(),
            "--no-split-index".into(),
            "--no-untracked-cache".into(),
        ])?;
        let after = run(&["write-tree".into()])?.stdout;
        let after = std::str::from_utf8(&after)
            .map_err(|_| Error::MalformedOutput("invalid tree ID"))?
            .trim()
            .to_owned();
        check_oid(after.as_bytes())?;
        if before == after {
            return Err(Error::InvalidInput("selection does not change the index"));
        }
        let diff = run(&[
            "diff".into(),
            "--binary".into(),
            "--full-index".into(),
            "--no-ext-diff".into(),
            "--no-textconv".into(),
            "--no-color".into(),
            before.clone().into(),
            after.clone().into(),
            "--".into(),
        ])?;
        let prepared = regular(
            File::open(temp.path().join("index")).map_err(io)?,
            MAX_INDEX,
            cancellation,
        )?
        .bytes;
        self.verify(policy, cancellation)?;
        if self.mutation_head(policy, cancellation)? != head
            || index(&dir, cancellation)? != original
        {
            return Err(Error::StalePreview);
        }
        for (path, file) in selected.iter().zip(&files) {
            file.verify_ancestry(cancellation)?;
            if &observe(self, path, cancellation, &mut AncestryCache::default())? != file {
                return Err(Error::StalePreview);
            }
        }
        Ok(IndexPreview {
            action,
            repository: self.clone(),
            paths: selected,
            head,
            index: original,
            files,
            prepared,
            diff,
            operation_output,
            before_tree: before,
            after_tree: after,
        })
    }
    fn verify_preview(
        &self,
        preview: &IndexPreview,
        directory: &File,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<(), Error> {
        if self.mutation_head(policy, cancellation)? != preview.head
            || index(directory, cancellation)? != preview.index
        {
            return Err(Error::StalePreview);
        }
        for (path, file) in preview.paths.iter().zip(&preview.files) {
            file.verify_ancestry(cancellation)?;
            if &observe(self, path, cancellation, &mut AncestryCache::default())? != file {
                return Err(Error::StalePreview);
            }
        }
        self.verify(policy, cancellation)?;
        self.check_stage_extensions(policy, cancellation)?;
        Ok(())
    }
    pub fn apply_index(
        &self,
        preview: IndexPreview,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<(), Error> {
        let _operation = self.try_operation()?;
        if self.root != preview.repository.root
            || self.git_dir != preview.repository.git_dir
            || self.root_identity != preview.repository.root_identity
            || self.git_identity != preview.repository.git_identity
        {
            return Err(Error::StaleRepository);
        }
        cancelled(cancellation)?;
        self.verify(policy, cancellation)?;
        let lock = IndexLock::acquire(directory(self)?)?;
        self.verify_preview(&preview, &lock.directory, policy, cancellation)?;
        // Vorbereitete lose Objekte könnten durch eine externe aggressive GC verschwunden sein.
        let verified_diff = self.read(
            &[
                "diff".into(),
                "--binary".into(),
                "--full-index".into(),
                "--no-ext-diff".into(),
                "--no-textconv".into(),
                "--no-color".into(),
                preview.before_tree.clone().into(),
                preview.after_tree.clone().into(),
                "--".into(),
            ],
            policy,
            cancellation,
        )?;
        if verified_diff.stdout != preview.diff.stdout {
            return Err(Error::StalePreview);
        }
        cancelled(cancellation)?;
        lock.publish(
            &preview.prepared,
            preview.index.as_ref().map(|i| i.stamp.mode),
            cancellation,
            |directory| self.verify_preview(&preview, directory, policy, cancellation),
        )
    }
}

// Derselbe gehaltene Dateibaum schützt Index-, Wechsel- und Pullvorschauen.
pub(crate) const MAX_PULL_PATHS: usize = 65_536;
#[derive(Debug)]
pub(crate) struct SwitchBindings {
    index: Option<Blob>,
    files: Vec<(RepoPath, ObservedFile)>,
}
impl SwitchBindings {
    pub(crate) fn capture(
        repo: &Repository,
        paths: Vec<RepoPath>,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        if paths.len() > MAX_FILES {
            return Err(Error::InvalidInput("switch preview limit: 128 paths"));
        }
        Self::capture_files(repo,paths,cancel,"switch preview limit: 64 MiB working files")
    }
    pub(crate) fn capture_pull(repo:&Repository,paths:Vec<RepoPath>,cancel:&Cancellation)->Result<Self,Error>{
        if paths.len()>MAX_PULL_PATHS{return Err(Error::InvalidInput("pull preview limit: 65536 paths"));}
        Self::capture_files(repo,paths,cancel,"pull preview limit: 64 MiB working files")
    }
    fn capture_files(repo:&Repository,paths:Vec<RepoPath>,cancel:&Cancellation,total_error:&'static str)->Result<Self,Error>{
        let index = index(&directory(repo)?, cancel)?;
        let mut cache = AncestryCache::default();
        let mut total = 0;
        let mut files = Vec::new();
        for path in paths {
            let file = observe(repo, &path, cancel, &mut cache)?;
            total += match &file.state {
                FileState::Regular(b) => b.bytes.len(),
                FileState::Symlink { target, .. } => target.len(),
                FileState::Missing => 0,
            };
            if total > MAX_TOTAL {
                return Err(Error::InvalidInput(total_error));
            }
            files.push((path, file));
        }
        Ok(Self { index, files })
    }
    pub(crate) fn verify(&self, repo: &Repository, cancel: &Cancellation) -> Result<(), Error> {
        if index(&directory(repo)?, cancel)? != self.index {
            return Err(Error::StalePreview);
        }
        let mut cache = AncestryCache::default();
        for (path, file) in &self.files {
            file.verify_ancestry(cancel)?;
            if observe(repo, path, cancel, &mut cache)? != *file {
                return Err(Error::StalePreview);
            }
        }
        Ok(())
    }
}
