//! Vollständiger freigegebener Indexcommit; Veröffentlichung und Locks bleiben bei Git.
use crate::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    },
    sync::Arc,
    time::Instant,
};
pub(crate) const LIMIT: usize = 32 * 1024 * 1024;
pub(crate) const META_LIMIT: usize = 512 * 1024;
pub(crate) fn io(e: std::io::Error) -> Error {
    Error::Io(e.to_string())
}
pub(crate) fn hash(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}
pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub(crate) fn path(bytes: &[u8]) -> PathBuf {
    PathBuf::from(OsString::from_vec(bytes.to_vec()))
}
pub(crate) fn raw(path: &Path) -> Vec<u8> {
    path.as_os_str().as_bytes().to_vec()
}
pub(crate) fn args(a: &[&str]) -> Vec<OsString> {
    a.iter().map(Into::into).collect()
}
pub(crate) fn stop(c: &Cancellation) -> Result<(), Error> {
    if c.is_cancelled() {
        Err(Error::Cancelled(GitOutput::empty()))
    } else {
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct Stamp {
    dev: u64,
    ino: u64,
    len: u64,
    mode: u32,
    mt: i64,
    mtn: i64,
    ct: i64,
    ctn: i64,
}
impl Stamp {
    fn new(m: &fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            mode: m.mode(),
            mt: m.mtime(),
            mtn: m.mtime_nsec(),
            ct: m.ctime(),
            ctn: m.ctime_nsec(),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct Binding {
    pub root: usize,
    pub name: Vec<u8>,
    ancestors: Vec<(u64, u64)>,
    stamp: Option<Stamp>,
    digest: Vec<u8>,
}
pub(crate) struct Bound {
    pub binding: Binding,
    pub held: Vec<Arc<File>>,
    pub bytes: Option<Vec<u8>>,
}
fn directory(p: &Path) -> Result<File, Error> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(p)
        .map_err(io)
}
fn open_at(parent: &File, name: &[u8], flags: i32) -> Result<Option<File>, Error> {
    let n = CString::new(name).map_err(|_| Error::InvalidInput("NUL in file name"))?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            n.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd >= 0 {
        return Ok(Some(unsafe { File::from_raw_fd(fd) }));
    }
    let e = std::io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::ENOENT) {
        Ok(None)
    } else {
        Err(io(e))
    }
}
pub(crate) fn file_bytes(
    mut f: &File,
    limit: usize,
    c: &Cancellation,
) -> Result<(Stamp, Vec<u8>), Error> {
    stop(c)?;
    let before = f.metadata().map_err(io)?;
    if !before.is_file() || before.len() > limit as u64 {
        return Err(Error::InvalidInput(
            "commit input must be a bounded regular file",
        ));
    }
    let stamp = Stamp::new(&before);
    let mut bytes = Vec::new();
    let mut block = [0u8; 65536];
    loop {
        stop(c)?;
        let n = f.read(&mut block).map_err(io)?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > limit {
            return Err(Error::InvalidInput("commit input size limit"));
        }
        bytes.extend_from_slice(&block[..n]);
    }
    if Stamp::new(&f.metadata().map_err(io)?) != stamp {
        return Err(Error::StalePreview);
    }
    Ok((stamp, bytes))
}
pub(crate) fn bind(
    roots: &[Vec<u8>],
    root: usize,
    name: &[u8],
    limit: usize,
    c: &Cancellation,
) -> Result<Bound, Error> {
    stop(c)?;
    RepoPath::new(name.to_vec())?;
    let mut current = Arc::new(directory(&path(&roots[root]))?);
    let mut held = vec![current.clone()];
    let mut ancestors = Vec::new();
    let parts: Vec<_> = name.split(|b| *b == b'/').collect();
    if parts.len() > 64 {
        return Err(Error::InvalidInput("commit metadata path depth limit: 64"));
    }
    for (i, part) in parts.iter().enumerate() {
        let m = current.metadata().map_err(io)?;
        ancestors.push((m.dev(), m.ino()));
        let last = i + 1 == parts.len();
        let opened = open_at(
            &current,
            part,
            libc::O_RDONLY | if last { 0 } else { libc::O_DIRECTORY },
        )?;
        let Some(file) = opened else {
            return Ok(Bound {
                binding: Binding {
                    root,
                    name: name.to_vec(),
                    ancestors,
                    stamp: None,
                    digest: Vec::new(),
                },
                held,
                bytes: None,
            });
        };
        if last {
            let (stamp, bytes) = file_bytes(&file, limit, c)?;
            held.push(Arc::new(file));
            return Ok(Bound {
                binding: Binding {
                    root,
                    name: name.to_vec(),
                    ancestors,
                    stamp: Some(stamp),
                    digest: hash(&bytes),
                },
                held,
                bytes: Some(bytes),
            });
        }
        current = Arc::new(file);
        held.push(current.clone());
    }
    Err(Error::InvalidInput("invalid bound path"))
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Ident {
    pub full: Vec<u8>,
    pub name: Vec<u8>,
    pub email: Vec<u8>,
    pub date: Vec<u8>,
}
fn ident(output: &[u8]) -> Result<Ident, Error> {
    let full = output
        .strip_suffix(b"\n")
        .ok_or(Error::MalformedOutput("identity terminator"))?
        .to_vec();
    if full.len() > 4096 || full.contains(&0) || full.contains(&b'\n') {
        return Err(Error::InvalidInput("invalid Git identity"));
    }
    let mut tail = full.rsplitn(3, |b| *b == b' ');
    let zone = tail
        .next()
        .ok_or(Error::MalformedOutput("identity timezone"))?;
    let seconds = tail
        .next()
        .ok_or(Error::MalformedOutput("identity timestamp"))?;
    let rest = tail.next().ok_or(Error::MalformedOutput("identity name"))?;
    let left = rest
        .iter()
        .rposition(|b| *b == b'<')
        .ok_or(Error::MalformedOutput("identity email"))?;
    let email = rest
        .get(left + 1..rest.len() - 1)
        .ok_or(Error::MalformedOutput("identity email"))?;
    if !rest.ends_with(b">") || left == 0 {
        return Err(Error::MalformedOutput("identity email"));
    }
    let name = rest[..left]
        .strip_suffix(b" ")
        .unwrap_or(&rest[..left])
        .to_vec();
    let mut date = b"@".to_vec();
    date.extend_from_slice(seconds);
    date.push(b' ');
    date.extend_from_slice(zone);
    let email = email.to_vec();
    Ok(Ident {
        full,
        name,
        email,
        date,
    })
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Context {
    pub version: u32,
    pub git: Vec<u8>,
    pub roots: Vec<Vec<u8>>,
    pub identities: Vec<(u64, u64)>,
    pub common: (u64, u64),
    pub branch: Vec<u8>,
    pub old: Vec<u8>,
    pub parents: Vec<Vec<u8>>,
    pub tree: Vec<u8>,
    pub message: Vec<u8>,
    pub author: Ident,
    pub committer: Ident,
    pub config: Vec<u8>,
    pub hooks: Vec<u8>,
    pub required_hooks: Vec<Vec<u8>>,
    pub original: Vec<u8>,
    pub bindings: Vec<Binding>,
    pub hook_dir: Vec<u8>,
    pub marker: Vec<u8>,
}
pub struct CommitPreview {
    pub(crate) repository: Repository,
    pub(crate) context: Context,
    pub(crate) _held: Vec<Arc<File>>,
    pub(crate) temp: Option<tempfile::TempDir>,
    pub(crate) index: PathBuf,
    pub(crate) message_file: PathBuf,
    pub(crate) helper: PathBuf,
    diff: GitOutput,
    entries: GitOutput,
    signing: Vec<u8>,
}
impl Drop for CommitPreview {
    fn drop(&mut self) {
        if let Some(temp) = self.temp.take() {
            // Invalidierung und Fensterschließen laufen auf GTK; große Scratchbäume nur auf einem Worker löschen.
            let directory = temp.keep();
            let _ = std::thread::Builder::new()
                .name("git-preview-cleanup".into())
                .spawn(move || {
                    let _ = fs::remove_dir_all(directory);
                });
        }
    }
}
impl std::fmt::Debug for CommitPreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommitPreview")
            .field("branch", &self.context.branch)
            .field("tree", &self.context.tree)
            .finish_non_exhaustive()
    }
}
impl CommitPreview {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn branch(&self) -> &[u8] {
        &self.context.branch
    }
    pub fn parents(&self) -> &[Vec<u8>] {
        &self.context.parents
    }
    pub fn tree(&self) -> &[u8] {
        &self.context.tree
    }
    pub fn message(&self) -> &[u8] {
        &self.context.message
    }
    pub fn author(&self) -> &[u8] {
        &self.context.author.full
    }
    pub fn committer(&self) -> &[u8] {
        &self.context.committer.full
    }
    pub fn signing(&self) -> &[u8] {
        &self.signing
    }
    pub fn diff(&self) -> &GitOutput {
        &self.diff
    }
    pub fn entries(&self) -> &GitOutput {
        &self.entries
    }
}
#[derive(Debug)]
pub struct CommitReport {
    pub result: Result<GitOutput, Error>,
    pub state: Result<SwitchState, Error>,
    pub published: Option<Vec<u8>>,
}
pub(crate) struct Budget {
    policy: Policy,
    start: Instant,
    out: usize,
    err: usize,
}
impl Budget {
    pub(crate) fn new(policy: Policy) -> Self {
        Self {
            policy,
            start: Instant::now(),
            out: policy.stdout_bytes,
            err: policy.stderr_bytes,
        }
    }
    pub(crate) fn policy(&self) -> Result<Policy, Error> {
        let timeout = self.policy.timeout.saturating_sub(self.start.elapsed());
        if timeout.is_zero() {
            return Err(Error::TimedOut(GitOutput::empty()));
        }
        if self.out == 0 || self.err == 0 {
            return Err(Error::OutputLimit(GitOutput::empty()));
        }
        Ok(Policy {
            timeout,
            stdout_bytes: self.out,
            stderr_bytes: self.err,
            ..self.policy
        })
    }
    fn account(&mut self, out: &GitOutput) {
        self.out = self.out.saturating_sub(out.stdout.len());
        self.err = self.err.saturating_sub(out.stderr.len());
    }
}
impl Repository {
    pub(crate) fn commit_read(
        &self,
        a: Vec<OsString>,
        b: &mut Budget,
        c: &Cancellation,
    ) -> Result<GitOutput, Error> {
        self.verify(b.policy()?, c)?;
        let out = self.git.checked_env(
            &self.root,
            &a,
            b.policy()?,
            c,
            &[("GIT_NO_REPLACE_OBJECTS".into(), "1".into())],
        )?;
        b.account(&out);
        Ok(out)
    }
    pub(crate) fn commit_config(&self, b: &mut Budget, c: &Cancellation) -> Result<Vec<u8>, Error> {
        match self.commit_read(
            args(&[
                "config",
                "--null",
                "--list",
                "--show-origin",
                "--show-scope",
            ]),
            b,
            c,
        ) {
            Ok(out) => Ok(hash(&out.stdout)),
            Err(error) => Err(crate::clear_config_stdout(error)),
        }
    }
    pub(crate) fn commit_hooks(
        &self,
        dir: &Path,
        c: &Cancellation,
    ) -> Result<(Vec<u8>, Vec<Vec<u8>>), Error> {
        let mut names = Vec::new();
        match fs::read_dir(dir) {
            Ok(list) => {
                for e in list {
                    stop(c)?;
                    let e = e.map_err(io)?;
                    let n = e.file_name().as_bytes().to_vec();
                    if n.len() > 1024 || n.contains(&b'/') || n.contains(&0) {
                        return Err(Error::InvalidInput("hook name limit"));
                    }
                    names.push(n);
                    if names.len() > 256 {
                        return Err(Error::InvalidInput("hook directory limit: 256"));
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(io(e)),
        }
        names.sort();
        let mut digest = Sha256::new();
        let mut exec = Vec::new();
        let mut total = 0;
        for n in names {
            stop(c)?;
            let file = dir.join(OsString::from_vec(n.clone()));
            let m = match fs::metadata(&file) {
                Ok(m) => m,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(io(e)),
            };
            if m.mode() & 0o111 == 0 {
                continue;
            }
            if !m.is_file() || m.len() > 1024 * 1024 {
                return Err(Error::InvalidInput(
                    "executable hooks must be regular files up to 1 MiB",
                ));
            }
            let f = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                .open(&file)
                .map_err(io)?;
            let (stamp, bytes) = file_bytes(&f, 1024 * 1024, c)?;
            total += bytes.len();
            if total > 4 * 1024 * 1024 {
                return Err(Error::InvalidInput("hook content limit: 4 MiB"));
            }
            digest.update((n.len() as u64).to_le_bytes());
            digest.update(&n);
            digest.update(serde_json::to_vec(&stamp).map_err(|e| Error::Io(e.to_string()))?);
            digest.update(hash(&bytes));
            exec.push(n);
        }
        Ok((digest.finalize().to_vec(), exec))
    }
    pub(crate) fn commit_verify(
        &self,
        ctx: &Context,
        b: &mut Budget,
        c: &Cancellation,
    ) -> Result<(), Error> {
        self.verify(b.policy()?, c)?;
        let format = if ctx.old.len() == 64 {
            b"sha256".as_slice()
        } else {
            b"sha1".as_slice()
        };
        if self.commit_source(format, b, c)? != (ctx.branch.clone(), ctx.old.clone()) {
            return Err(Error::StalePreview);
        }
        if self.operation_identity()? != ctx.common {
            return Err(Error::StaleRepository);
        }
        for (p, id) in ctx.roots.iter().zip(&ctx.identities) {
            if identity(&path(p))? != *id {
                return Err(Error::StaleRepository);
            }
        }
        if self.commit_config(b, c)? != ctx.config
            || self.commit_hooks(&path(&ctx.original), c)?.0 != ctx.hooks
        {
            return Err(Error::StalePreview);
        }
        for expected in &ctx.bindings {
            let actual = bind(&ctx.roots, expected.root, &expected.name, LIMIT, c)?;
            if actual.binding != *expected {
                return Err(Error::StalePreview);
            }
        }
        Ok(())
    }
}
const HOOK_SCRIPT: &[u8] =
    b"#!/bin/sh\nexec \"$FASTRA_COMMIT_HELPER\" --fastra-git-commit-hook \"$0\" \"$@\"\n";
fn validate_hook_mirror(ctx: &Context) -> Result<(), Error> {
    let dir = path(&ctx.hook_dir);
    let mut reference = false;
    let mut present = Vec::new();
    for item in fs::read_dir(&dir).map_err(io)? {
        let item = item.map_err(io)?;
        let p = item.path();
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&p)
            .map_err(io)?;
        let (_, bytes) = file_bytes(&file, 512, &Cancellation::default())?;
        let name = CString::new(p.as_os_str().as_bytes())
            .map_err(|_| Error::InvalidInput("invalid private hook path"))?;
        if bytes != HOOK_SCRIPT || unsafe { libc::access(name.as_ptr(), libc::X_OK) } != 0 {
            return Err(Error::InvalidInput(
                "private hook validator is missing, changed or not executable",
            ));
        }
        reference |= item.file_name() == "reference-transaction";
        present.push(item.file_name().as_bytes().to_vec());
    }
    present.sort();
    if present != ctx.required_hooks {
        return Err(Error::InvalidInput(
            "private hook mirror is incomplete or changed",
        ));
    }
    if !reference {
        return Err(Error::InvalidInput(
            "private reference validator is missing",
        ));
    }
    Ok(())
}
fn write_new(p: &Path, bytes: &[u8], mode: u32) -> Result<(), Error> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(p)
        .map_err(io)?;
    f.write_all(bytes).map_err(io)
}
fn line_oid(out: &GitOutput) -> Result<Vec<u8>, Error> {
    let x = out
        .stdout
        .strip_suffix(b"\n")
        .ok_or(Error::MalformedOutput("object ID terminator"))?;
    check_oid(x)?;
    Ok(x.to_vec())
}
fn alternate(p: &Path) -> OsString {
    let mut q = vec![b'"'];
    for b in p.as_os_str().as_bytes() {
        match *b {
            b'"' | b'\\' => {
                q.push(b'\\');
                q.push(*b);
            }
            32..=126 => q.push(*b),
            _ => q.extend_from_slice(format!("\\{b:03o}").as_bytes()),
        }
    }
    q.push(b'"');
    OsString::from_vec(q)
}
impl Repository {
    fn commit_source(
        &self,
        format: &[u8],
        b: &mut Budget,
        c: &Cancellation,
    ) -> Result<(Vec<u8>, Vec<u8>), Error> {
        let branch = match self.commit_read(args(&["symbolic-ref", "--quiet", "HEAD"]), b, c) {
            Ok(out) => out
                .stdout
                .strip_suffix(b"\n")
                .ok_or(Error::MalformedOutput("branch terminator"))?
                .to_vec(),
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) => b"HEAD".to_vec(),
            Err(e) => return Err(e),
        };
        if branch == b"HEAD" {
            let out = self.commit_read(args(&["rev-parse", "--verify", "HEAD"]), b, c)?;
            return Ok((branch, line_oid(&out)?));
        }
        let short = branch
            .strip_prefix(b"refs/heads/")
            .ok_or(Error::InvalidInput(
                "commit requires a local branch or detached HEAD",
            ))?;
        if branch.len() > 1024 || short.is_empty() || short.starts_with(b"-") {
            return Err(Error::InvalidInput("local branch name limit"));
        }
        let mut a = args(&["check-ref-format", "--branch"]);
        a.push(OsString::from_vec(short.to_vec()));
        if self.commit_read(a, b, c)?.stdout.strip_suffix(b"\n") != Some(short) {
            return Err(Error::InvalidInput("literal branch required"));
        }
        let mut quiet = args(&["show-ref", "--verify", "--quiet", "--"]);
        quiet.push(OsString::from_vec(branch.clone()));
        let exists = match self.commit_read(quiet, b, c) {
            Ok(_) => true,
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) => false,
            Err(e) => return Err(e),
        };
        let old = if exists {
            let mut a = args(&["show-ref", "--verify", "--hash", "--"]);
            a.push(OsString::from_vec(branch.clone()));
            line_oid(&self.commit_read(a, b, c)?)?
        } else {
            vec![b'0'; if format == b"sha256" { 64 } else { 40 }]
        };
        Ok((branch, old))
    }
    pub fn prepare_commit(
        &self,
        message: Vec<u8>,
        helper: PathBuf,
        policy: Policy,
        c: &Cancellation,
    ) -> Result<CommitPreview, Error> {
        let mut owned = self.clone();
        owned.git.terminate_on_parent_loss = true;
        let policy = Policy {
            stdout_bytes: policy.stdout_bytes.min(4 * 1024 * 1024),
            stderr_bytes: policy.stderr_bytes.min(128 * 1024),
            timeout: policy.timeout.min(std::time::Duration::from_secs(30)),
            ..policy
        };
        owned.prepare_commit_inner(message, helper, policy, c)
    }
    fn prepare_commit_inner(
        &self,
        mut message: Vec<u8>,
        helper: PathBuf,
        policy: Policy,
        c: &Cancellation,
    ) -> Result<CommitPreview, Error> {
        let mut budget = Budget::new(policy);
        stop(c)?;
        if message.len() > 128 * 1024
            || message.contains(&0)
            || std::str::from_utf8(&message).map_or(true, |s| s.trim().is_empty())
        {
            return Err(Error::InvalidInput(
                "enter a UTF-8 commit message up to 128 KiB without NUL",
            ));
        }
        if !message.ends_with(b"\n") {
            message.push(b'\n');
        }
        if !helper.is_absolute() || !fs::metadata(&helper).map_err(io)?.is_file() {
            return Err(Error::InvalidInput(
                "absolute commit helper executable required",
            ));
        }
        let version = self.commit_read(args(&["--version"]), &mut budget, c)?;
        let text = std::str::from_utf8(&version.stdout).map_err(|_| Error::Unavailable)?;
        let v = text
            .strip_prefix("git version ")
            .ok_or(Error::Unavailable)?;
        let mut parts = v.split('.');
        let major = parts
            .next()
            .and_then(|x| x.parse::<u32>().ok())
            .unwrap_or(0);
        let minor = parts
            .next()
            .and_then(|x| x.parse::<u32>().ok())
            .unwrap_or(0);
        if major < 2 || (major == 2 && minor < 43) {
            return Err(Error::InvalidInput(
                "safe commit validation requires Git 2.43 or newer",
            ));
        }
        let format = self
            .commit_read(args(&["rev-parse", "--show-object-format"]), &mut budget, c)?
            .stdout;
        let format = format
            .strip_suffix(b"\n")
            .ok_or(Error::MalformedOutput("object format"))?;
        if !matches!(format, b"sha1" | b"sha256") {
            return Err(Error::InvalidInput("unsupported Git object format"));
        }
        match self.commit_read(
            args(&["config", "--get", "extensions.refStorage"]),
            &mut budget,
            c,
        ) {
            Ok(out) if out.stdout != b"files\n" => {
                return Err(Error::InvalidInput(
                    "commit validation currently requires the Git files ref backend",
                ))
            }
            Ok(_) => {}
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) => {}
            Err(e) => return Err(e),
        }
        let common = output_path(
            &self
                .commit_read(
                    args(&["rev-parse", "--path-format=absolute", "--git-common-dir"]),
                    &mut budget,
                    c,
                )?
                .stdout,
        )?;
        let roots = vec![raw(&self.root), raw(&self.git_dir), raw(&common)];
        let identities = roots
            .iter()
            .map(|p| identity(&path(p)))
            .collect::<Result<Vec<_>, _>>()?;
        let operation = self.operation_identity()?;
        let mut held = Vec::new();
        for p in &roots {
            held.push(Arc::new(directory(&path(p))?));
        }
        let (branch, old) = self.commit_source(format, &mut budget, c)?;
        let mut bindings = Vec::new();
        let head = bind(&roots, 1, b"HEAD", 4096, c)?;
        let head_bytes = head.bytes.as_ref().ok_or(Error::StaleRepository)?;
        if branch != b"HEAD" {
            let mut expected = b"ref: ".to_vec();
            expected.extend_from_slice(&branch);
            expected.push(b'\n');
            if *head_bytes != expected {
                return Err(Error::InvalidInput(
                    "indirect symbolic branch aliases require the Git CLI",
                ));
            }
        }
        bindings.push(head.binding);
        held.extend(head.held);
        if branch != b"HEAD" {
            let bound = bind(&roots, 2, &branch, 4096, c)?;
            bindings.push(bound.binding);
            held.extend(bound.held);
        }
        let packed = bind(&roots, 2, b"packed-refs", LIMIT, c)?;
        bindings.push(packed.binding);
        held.extend(packed.held);
        let mut parents = if old.iter().all(|b| *b == b'0') {
            Vec::new()
        } else {
            vec![old.clone()]
        };
        for name in [
            "MERGE_HEAD",
            "MERGE_MODE",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "REBASE_HEAD",
            "rebase-merge",
            "rebase-apply",
            "sequencer",
        ] {
            let bound = bind(&roots, 1, name.as_bytes(), 8192, c)?;
            if name == "MERGE_HEAD" {
                if let Some(bytes) = &bound.bytes {
                    for oid in bytes.split(|b| *b == b'\n').filter(|x| !x.is_empty()) {
                        check_oid(oid)?;
                        if parents.len() >= 64 {
                            return Err(Error::InvalidInput("merge parent limit: 64"));
                        }
                        parents.push(oid.to_vec());
                    }
                }
            } else if name != "MERGE_MODE" && bound.bytes.is_some() {
                return Err(Error::InvalidInput(
                    "finish cherry-pick, revert or rebase with Git before committing here",
                ));
            }
            bindings.push(bound.binding);
            held.extend(bound.held);
        }
        let original = output_path(
            &self
                .commit_read(
                    args(&["rev-parse", "--path-format=absolute", "--git-path", "hooks"]),
                    &mut budget,
                    c,
                )?
                .stdout,
        )?;
        let (hooks, names) = self.commit_hooks(&original, c)?;
        let config = self.commit_config(&mut budget, c)?;
        let author = ident(
            &self
                .commit_read(args(&["var", "GIT_AUTHOR_IDENT"]), &mut budget, c)?
                .stdout,
        )?;
        let committer = ident(
            &self
                .commit_read(args(&["var", "GIT_COMMITTER_IDENT"]), &mut budget, c)?
                .stdout,
        )?;
        let mut signing = Vec::new();
        for key in ["commit.gpgSign", "gpg.format", "user.signingKey"] {
            signing.extend_from_slice(key.as_bytes());
            signing.extend_from_slice(b": ");
            match self.commit_read(
                vec!["config".into(), "--get".into(), key.into()],
                &mut budget,
                c,
            ) {
                Ok(out) => {
                    if key == "user.signingKey" {
                        signing.extend_from_slice(b"(configured)\n");
                    } else {
                        signing.extend_from_slice(&out.stdout);
                    }
                }
                Err(Error::GitFailed(out)) if out.exit_code == Some(1) => {
                    signing.extend_from_slice(b"(Git default)\n")
                }
                Err(e) => return Err(e),
            }
        }
        let temp = tempfile::Builder::new()
            .prefix("fastra-commit-")
            .tempdir_in("/tmp")
            .map_err(io)?;
        let bare = temp.path().join("repository");
        let empty = temp.path().join("preview-hooks");
        let wrapper = temp.path().join("commit-hooks");
        fs::create_dir(&empty).map_err(io)?;
        fs::create_dir(&wrapper).map_err(io)?;
        let original_objects = output_path(
            &self
                .commit_read(
                    args(&[
                        "rev-parse",
                        "--path-format=absolute",
                        "--git-path",
                        "objects",
                    ]),
                    &mut budget,
                    c,
                )?
                .stdout,
        )?;
        let mut init = args(&["-c"]);
        init.push(OsString::from_vec(
            [
                b"init.templateDir=".as_slice(),
                empty.as_os_str().as_bytes(),
            ]
            .concat(),
        ));
        init.extend(args(&["-c"]));
        init.push(OsString::from_vec(
            [b"core.hooksPath=".as_slice(), empty.as_os_str().as_bytes()].concat(),
        ));
        init.extend(args(&["init", "--bare", "--quiet"]));
        init.push(format!("--object-format={}", std::str::from_utf8(format).unwrap()).into());
        init.push(bare.as_os_str().to_owned());
        let out = self
            .git
            .checked_env(temp.path(), &init, budget.policy()?, c, &[])?;
        budget.account(&out);
        if !fs::symlink_metadata(&bare)
            .map_err(io)?
            .file_type()
            .is_dir()
        {
            return Err(Error::InvalidInput(
                "Git scratch output is not a real private directory",
            ));
        }
        let _scratch_directory = directory(&bare)?;
        let original_index = bind(&roots, 1, b"index", LIMIT, c)?;
        if let Some(bytes) = &original_index.bytes {
            write_new(&bare.join("index"), bytes, 0o600)?;
        }
        let mut copied = std::collections::HashMap::<Vec<u8>, Vec<u8>>::new();
        let mut total = 0;
        for dir in [&self.git_dir, &common] {
            for item in fs::read_dir(dir).map_err(io)? {
                stop(c)?;
                let item = item.map_err(io)?;
                let name = item.file_name().as_bytes().to_vec();
                let Some(suffix) = name.strip_prefix(b"sharedindex.") else {
                    continue;
                };
                if !matches!(suffix.len(), 40 | 64) || !suffix.iter().all(u8::is_ascii_hexdigit) {
                    continue;
                }
                if copied.len() >= 64 {
                    return Err(Error::InvalidInput("shared index file limit: 64"));
                }
                let f = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
                    .open(item.path())
                    .map_err(io)?;
                let (_, bytes) = file_bytes(&f, LIMIT, c)?;
                if let Some(existing) = copied.get(&name) {
                    if existing != &hash(&bytes) {
                        return Err(Error::StalePreview);
                    }
                    continue;
                }
                total += bytes.len();
                if total > 64 * 1024 * 1024 {
                    return Err(Error::InvalidInput("shared index bytes limit: 64 MiB"));
                }
                write_new(&bare.join(OsString::from_vec(name.clone())), &bytes, 0o600)?;
                copied.insert(name, hash(&bytes));
            }
        }
        let env = vec![
            ("GIT_DIR".into(), bare.as_os_str().to_owned()),
            ("GIT_INDEX_FILE".into(), bare.join("index").into_os_string()),
            (
                "GIT_ALTERNATE_OBJECT_DIRECTORIES".into(),
                alternate(&original_objects),
            ),
            ("GIT_NO_REPLACE_OBJECTS".into(), "1".into()),
        ];
        let mut run =
            |a: Vec<OsString>, extra: &[(OsString, OsString)]| -> Result<GitOutput, Error> {
                let mut full = args(&["-c"]);
                full.push(OsString::from_vec(
                    [b"core.hooksPath=".as_slice(), empty.as_os_str().as_bytes()].concat(),
                ));
                full.extend(args(&[
                    "-c",
                    "core.splitIndex=false",
                    "-c",
                    "index.sparse=false",
                ]));
                full.extend(a);
                let mut env = env.clone();
                env.extend_from_slice(extra);
                let out = self
                    .git
                    .checked_env(temp.path(), &full, budget.policy()?, c, &env)?;
                budget.account(&out);
                Ok(out)
            };
        let tree = line_oid(&run(args(&["write-tree"]), &[])?)?;
        let index = temp.path().join("commit-index");
        let mut a = args(&["read-tree"]);
        a.push(OsString::from_vec(tree.clone()));
        run(
            a,
            &[("GIT_INDEX_FILE".into(), index.as_os_str().to_owned())],
        )?;
        let mut list = args(&["ls-tree", "-r", "--full-tree", "-z"]);
        list.push(OsString::from_vec(tree.clone()));
        let entries = run(list, &[])?;
        let source = if parents.is_empty() {
            line_oid(&run(args(&["mktree"]), &[])?)?
        } else {
            parents[0].clone()
        };
        let mut a = args(&[
            "diff",
            "--binary",
            "--full-index",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--no-renames",
            "--ignore-submodules=none",
            "--submodule=short",
        ]);
        a.extend([
            OsString::from_vec(source),
            OsString::from_vec(tree.clone()),
            "--".into(),
        ]);
        let diff = run(a, &[])?;
        let message_file = temp.path().join("message");
        write_new(&message_file, &message, 0o600)?;
        let mut required_hooks = names;
        if !required_hooks
            .iter()
            .any(|name| name == b"reference-transaction")
        {
            required_hooks.push(b"reference-transaction".to_vec());
        }
        required_hooks.sort();
        let context = Context {
            version: 1,
            git: raw(&self.git.executable),
            roots,
            identities,
            common: operation,
            branch,
            old,
            parents,
            tree,
            message,
            author,
            committer,
            config,
            hooks,
            required_hooks,
            original: raw(&original),
            bindings,
            hook_dir: raw(&wrapper),
            marker: raw(&temp.path().join("published")),
        };
        self.commit_verify(&context, &mut budget, c)?;
        for name in &context.required_hooks {
            write_new(
                &wrapper.join(OsString::from_vec(name.clone())),
                HOOK_SCRIPT,
                0o700,
            )?;
        }
        validate_hook_mirror(&context)?;
        Ok(CommitPreview {
            repository: self.clone(),
            context,
            _held: held,
            temp: Some(temp),
            index,
            message_file,
            helper,
            diff,
            entries,
            signing,
        })
    }
}
impl CommitPreview {
    pub fn execute(
        self,
        policy: Policy,
        c: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> CommitReport {
        let repo = &self.repository;
        let lease = repo.try_operation();
        let mut budget = Budget::new(policy);
        let result = match &lease {
            Err(e) => Err(e.clone()),
            Ok(_) => (|| {
                repo.commit_verify(&self.context, &mut budget, c)?;
                validate_hook_mirror(&self.context)?;
                stop(c)?;
                let serialized =
                    serde_json::to_vec(&self.context).map_err(|e| Error::Io(e.to_string()))?;
                if serialized.len() > META_LIMIT {
                    return Err(Error::InvalidInput("commit approval context limit"));
                }
                let context_file = self
                    .temp
                    .as_ref()
                    .expect("owned commit scratch")
                    .path()
                    .join("approval");
                write_new(&context_file, &serialized, 0o400)?;
                let mut env = vec![
                    ("GIT_INDEX_FILE".into(), self.index.as_os_str().to_owned()),
                    (
                        "FASTRA_COMMIT_CONTEXT".into(),
                        context_file.into_os_string(),
                    ),
                    (
                        "FASTRA_COMMIT_DIGEST".into(),
                        hex(&hash(&serialized)).into(),
                    ),
                    (
                        "FASTRA_COMMIT_HELPER".into(),
                        self.helper.as_os_str().to_owned(),
                    ),
                ];
                for (prefix, id) in [
                    ("GIT_AUTHOR", &self.context.author),
                    ("GIT_COMMITTER", &self.context.committer),
                ] {
                    env.extend([
                        (
                            format!("{prefix}_NAME").into(),
                            OsString::from_vec(id.name.clone()),
                        ),
                        (
                            format!("{prefix}_EMAIL").into(),
                            OsString::from_vec(id.email.clone()),
                        ),
                        (
                            format!("{prefix}_DATE").into(),
                            OsString::from_vec(id.date.clone()),
                        ),
                    ]);
                }
                env.extend([
                    ("GIT_TERMINAL_PROMPT".into(), "0".into()),
                    ("GIT_NO_LAZY_FETCH".into(), "1".into()),
                    ("GIT_ALLOW_PROTOCOL".into(), "".into()),
                    ("GIT_ASKPASS".into(), "/usr/bin/false".into()),
                    ("SSH_ASKPASS".into(), "/usr/bin/false".into()),
                    ("SSH_ASKPASS_REQUIRE".into(), "never".into()),
                    ("GIT_EDITOR".into(), "/usr/bin/false".into()),
                    ("GIT_NO_REPLACE_OBJECTS".into(), "1".into()),
                ]);
                let environment = fastra_process::Environment {
                    remove_prefixes: vec!["GIT_".into(), "FASTRA_COMMIT_".into()],
                    set: env,
                };
                let mut a = args(&["--no-pager", "-c"]);
                a.push(OsString::from_vec(
                    [
                        b"core.hooksPath=".as_slice(),
                        self.context.hook_dir.as_slice(),
                    ]
                    .concat(),
                ));
                a.extend(args(&["commit", "--cleanup=verbatim", "--file"]));
                a.push(self.message_file.as_os_str().to_owned());
                let out = fastra_process::run_with_stderr(
                    &repo.git.executable,
                    &repo.root,
                    &a,
                    budget.policy()?,
                    c,
                    &environment,
                    fastra_process::ParentLoss::Terminate,
                    observer,
                )
                .map_err(Error::from)?;
                if out.success() {
                    if read_published(&self.context).is_none() {
                        return Err(Error::InvalidInput("Git returned success without a validated commit transaction; inspect repository state"));
                    }
                    Ok(out)
                } else {
                    Err(Error::GitFailed(out))
                }
            })(),
        };
        let published = read_published(&self.context);
        let scan_cancel = Cancellation::default();
        let state = (|| {
            let b = Budget::new(policy);
            repo.verify(b.policy()?, &scan_cancel)?;
            if repo.operation_identity()? != self.context.common {
                return Err(Error::StaleRepository);
            }
            repo.switch_state(b.policy()?, &scan_cancel)
        })();
        drop(lease);
        CommitReport {
            result,
            state,
            published,
        }
    }
}
pub(crate) fn read_published(ctx: &Context) -> Option<Vec<u8>> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path(&ctx.marker))
        .ok()?;
    let (_, bytes) = file_bytes(&f, 256, &Cancellation::default()).ok()?;
    let oid = bytes.strip_suffix(b"\n")?;
    check_oid(oid).ok()?;
    if oid == ctx.old {
        return None;
    }
    Some(oid.to_vec())
}

#[cfg(all(test, target_os = "linux"))]
mod safety_tests {
    use super::*;
    use std::{os::unix::fs::PermissionsExt, process::Command};
    fn cli(root: &Path, a: &[&str]) -> Vec<u8> {
        let o = Command::new("/usr/bin/git")
            .current_dir(root)
            .args(a)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        o.stdout
    }
    #[test]
    fn missing_changed_or_nonexecuting_reference_validator_never_publishes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        cli(root, &["init", "-q", "-b", "main"]);
        cli(root, &["config", "user.name", "Fixture"]);
        cli(root, &["config", "user.email", "fixture@example.invalid"]);
        fs::write(root.join("file"), "initial\n").unwrap();
        cli(root, &["add", "file"]);
        cli(root, &["commit", "-qm", "initial"]);
        fs::write(root.join("file"), "staged\n").unwrap();
        cli(root, &["add", "file"]);
        let wrapper = root.join(".git/git-fixture");
        fs::write(&wrapper,"#!/bin/sh\nexport GIT_CONFIG_GLOBAL=/dev/null\nexport GIT_CONFIG_NOSYSTEM=1\nexec /usr/bin/git \"$@\"\n").unwrap();
        fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
        let repo = Git::new(wrapper)
            .unwrap()
            .discover(root, Policy::default(), &Cancellation::default())
            .unwrap();
        let old = cli(root, &["rev-parse", "HEAD"]);
        for mode in 0..3 {
            let p = repo
                .prepare_commit(
                    b"approved\n".to_vec(),
                    PathBuf::from("/usr/bin/true"),
                    Policy::default(),
                    &Cancellation::default(),
                )
                .unwrap();
            let reference = path(&p.context.hook_dir).join("reference-transaction");
            match mode {
                0 => fs::remove_file(&reference).unwrap(),
                1 => fs::set_permissions(&reference, fs::Permissions::from_mode(0o600)).unwrap(),
                _ => fs::write(&reference, "#!/bin/sh\nexit 0\n").unwrap(),
            };
            let r = p.execute(Policy::default(), &Cancellation::default(), &mut |_| {});
            assert!(matches!(r.result, Err(Error::InvalidInput(_))), "{r:?}");
            assert_eq!(cli(root, &["rev-parse", "HEAD"]), old);
        }
    }
    #[test]
    fn missing_original_hook_wrapper_never_publishes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        cli(root, &["init", "-q", "-b", "main"]);
        cli(root, &["config", "user.name", "Fixture"]);
        cli(root, &["config", "user.email", "fixture@example.invalid"]);
        cli(root, &["config", "commit.gpgsign", "false"]);
        fs::write(root.join("file"), "initial\n").unwrap();
        cli(root, &["add", "file"]);
        cli(root, &["commit", "-qm", "initial"]);
        fs::write(root.join("file"), "staged\n").unwrap();
        cli(root, &["add", "file"]);
        let hook = root.join(".git/hooks/pre-commit");
        fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).unwrap();
        let wrapper = root.join(".git/git-fixture");
        fs::write(&wrapper,"#!/bin/sh\nexport GIT_CONFIG_GLOBAL=/dev/null\nexport GIT_CONFIG_NOSYSTEM=1\nexec /usr/bin/git \"$@\"\n").unwrap();
        fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
        let repo = Git::new(wrapper)
            .unwrap()
            .discover(root, Policy::default(), &Cancellation::default())
            .unwrap();
        let old = cli(root, &["rev-parse", "HEAD"]);
        let index = fs::read(root.join(".git/index")).unwrap();
        let preview = repo
            .prepare_commit(
                b"approved\n".to_vec(),
                PathBuf::from("/usr/bin/true"),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap();
        fs::remove_file(path(&preview.context.hook_dir).join("pre-commit")).unwrap();
        let report = preview.execute(Policy::default(), &Cancellation::default(), &mut |_| {});
        assert!(
            matches!(report.result, Err(Error::InvalidInput(_))),
            "{report:?}"
        );
        assert_eq!(cli(root, &["rev-parse", "HEAD"]), old);
        assert_eq!(fs::read(root.join(".git/index")).unwrap(), index);
        assert!(hook.exists());
    }
}
