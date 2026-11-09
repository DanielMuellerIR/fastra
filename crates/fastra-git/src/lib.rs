//! Dünner, synchroner Git-CLI-Adapter. Der Host ruft ihn auf einer Worker-Queue auf.
#![cfg(unix)]
mod commit;
mod commit_hook;
pub use commit::{CommitPreview, CommitReport};
pub use commit_hook::entry as commit_hook_entry;
mod push;
pub use push::{PushPreview, PushTarget};
mod pull;
pub use pull::{PullPreview, PullReport, PullState, PullStrategy};
mod switch;
pub use switch::{SwitchPreview, SwitchState, SwitchReport};
mod branches;
pub use branches::{BranchCreationPreview, LocalBranches};
mod fetch;
pub use fetch::{FetchPlan, FetchReport, FetchSelection, OperationLease, RemoteFetch};
mod history;
pub use history::{
    Commit, CommitChanges, HistoricalBlob, HistoricalChange, HistoricalPair, History,
};
mod mutation;
mod status;
pub use mutation::{IndexAction, IndexPreview};
pub use status::{parse_status, Change, ChangeKind, Status};
use std::{
    ffi::OsString,
    fs,
    os::unix::{ffi::OsStringExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

pub use fastra_process::{Cancellation, Output as GitOutput, Policy};
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Unavailable,
    Launch(String),
    InvalidPolicy,
    InvalidInput(&'static str),
    StaleRepository,
    StalePreview,
    IndexLocked,
    IndexPublished(String),
    MalformedOutput(&'static str),
    Io(String),
    GitFailed(GitOutput),
    Cancelled(GitOutput),
    TimedOut(GitOutput),
    OutputLimit(GitOutput),
    Capture { message: String, output: GitOutput },
}
// Configwerte können Zugangsdaten außerhalb von URLs enthalten.
fn clear_config_stdout(mut error: Error) -> Error {
    match &mut error {
        Error::GitFailed(out) | Error::Cancelled(out) | Error::TimedOut(out)
        | Error::OutputLimit(out) | Error::Capture { output: out, .. } => out.stdout.clear(),
        _ => {}
    }
    error
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
impl From<fastra_process::Error> for Error {
    fn from(error: fastra_process::Error) -> Self {
        match error {
            fastra_process::Error::Unavailable => Self::Unavailable,
            fastra_process::Error::Launch(message) => Self::Launch(message),
            fastra_process::Error::InvalidPolicy => Self::InvalidPolicy,
            fastra_process::Error::Cancelled(output) => Self::Cancelled(output),
            fastra_process::Error::TimedOut(output) => Self::TimedOut(output),
            fastra_process::Error::OutputLimit(output) => Self::OutputLimit(output),
            fastra_process::Error::Capture { message, output } => Self::Capture { message, output },
        }
    }
}
/// Rohbytes bleiben Identität. Eine verlustbehaftete Anzeige ist Sache des Hosts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoPath(Vec<u8>);
impl RepoPath {
    pub fn new(bytes: Vec<u8>) -> Result<Self, Error> {
        if bytes.is_empty()
            || bytes.contains(&0)
            || bytes.starts_with(b"/")
            || bytes
                .split(|b| *b == b'/')
                .any(|part| part == b".." || part == b".")
        {
            return Err(Error::InvalidInput("invalid repository-relative path"));
        }
        Ok(Self(bytes))
    }
    pub fn bytes(&self) -> &[u8] {
        &self.0
    }
    fn argument(&self) -> OsString {
        OsString::from_vec(self.0.clone())
    }
}
/// Auch erfolgreich geparste Antworten behalten Warnungen und die Rohantwort.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadResult<T> {
    pub value: T,
    pub output: GitOutput,
}

#[derive(Debug, Clone)]
pub struct Git {
    executable: PathBuf,
    terminate_on_parent_loss: bool,
}
impl Git {
    /// Kein stiller Ersatz, wenn das konfigurierte CLI fehlt.
    pub fn new(executable: PathBuf) -> Result<Self, Error> {
        if !executable.is_absolute() {
            return Err(Error::InvalidInput("Git executable must be absolute"));
        }
        Ok(Self { executable, terminate_on_parent_loss: false })
    }
    pub fn discover(
        &self,
        directory: &Path,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<Repository, Error> {
        let directory =
            fs::canonicalize(directory).map_err(|error| Error::Io(error.to_string()))?;
        let root = self.checked(
            &directory,
            &["rev-parse".into(), "--show-toplevel".into()],
            policy,
            cancellation,
        )?;
        let root = output_path(&root.stdout)?;
        let git_dir = self.checked(
            &root,
            &["rev-parse".into(), "--absolute-git-dir".into()],
            policy,
            cancellation,
        )?;
        let git_dir = output_path(&git_dir.stdout)?;
        let root_identity = identity(&root)?;
        let git_identity = identity(&git_dir)?;
        Ok(Repository {
            git: self.clone(),
            root,
            git_dir,
            root_identity,
            git_identity,
        })
    }
    fn checked(
        &self,
        directory: &Path,
        arguments: &[OsString],
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<GitOutput, Error> {
        self.checked_env(directory, arguments, policy, cancellation, &[])
    }
    fn checked_env(
        &self,
        directory: &Path,
        arguments: &[OsString],
        policy: Policy,
        cancellation: &Cancellation,
        extra: &[(OsString, OsString)],
    ) -> Result<GitOutput, Error> {
        let mut all: Vec<OsString> = [
            "--no-pager",
            "-c",
            "color.ui=false",
            "-c",
            "core.fsmonitor=false",
        ]
        .into_iter()
        .map(Into::into)
        .collect();
        all.extend_from_slice(arguments);
        let mut environment = fastra_process::Environment {
            remove_prefixes: vec!["GIT_".into()],
            set: [
                ("GIT_TERMINAL_PROMPT", "0"),
                ("GIT_NO_LAZY_FETCH", "1"),
                ("GIT_ALLOW_PROTOCOL", ""),
                ("GIT_ASKPASS", "/usr/bin/false"),
                ("SSH_ASKPASS", "/usr/bin/false"),
                ("SSH_ASKPASS_REQUIRE", "never"),
                ("GIT_LITERAL_PATHSPECS", "1"),
                ("GIT_OPTIONAL_LOCKS", "0"),
                ("GIT_EDITOR", "/usr/bin/false"),
                ("GIT_SEQUENCE_EDITOR", "/usr/bin/false"),
            ]
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect(),
        };
        environment.set.extend_from_slice(extra);
        let result = if self.terminate_on_parent_loss {
            fastra_process::run_with_stderr(&self.executable,directory,&all,policy,cancellation,&environment,fastra_process::ParentLoss::Terminate,&mut |_|{})?
        } else {
            fastra_process::run(&self.executable,directory,&all,policy,cancellation,&environment)?
        };
        if result.success() {
            Ok(result)
        } else {
            Err(Error::GitFailed(result))
        }
    }
}
fn output_path(bytes: &[u8]) -> Result<PathBuf, Error> {
    let path = bytes
        .strip_suffix(b"\n")
        .ok_or(Error::MalformedOutput("unterminated Git path"))?;
    if path.is_empty() || path.contains(&0) {
        return Err(Error::MalformedOutput("invalid Git path"));
    }
    let path = PathBuf::from(OsString::from_vec(path.to_vec()));
    if !path.is_absolute() {
        return Err(Error::MalformedOutput("nonabsolute Git path"));
    }
    Ok(path)
}
fn identity(path: &Path) -> Result<(u64, u64), Error> {
    let metadata = fs::metadata(path).map_err(|error| Error::Io(error.to_string()))?;
    if !metadata.is_dir() {
        return Err(Error::StaleRepository);
    }
    Ok((metadata.dev(), metadata.ino()))
}
#[derive(Debug, Clone)]
pub struct Repository {
    git: Git,
    root: PathBuf,
    git_dir: PathBuf,
    root_identity: (u64, u64),
    git_identity: (u64, u64),
}
#[derive(Debug, Clone, Copy)]
pub enum DiffTarget {
    WorkingTree,
    Index,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Branch {
    pub full_name: Vec<u8>,
    pub oid: Vec<u8>,
    pub current: bool,
    pub worktree_path: Vec<u8>,
}
impl Repository {
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn git_directory(&self) -> &Path {
        &self.git_dir
    }
    fn verify(&self, policy: Policy, cancellation: &Cancellation) -> Result<(), Error> {
        if identity(&self.root)? != self.root_identity
            || identity(&self.git_dir)? != self.git_identity
        {
            return Err(Error::StaleRepository);
        }
        let actual = self.git.checked(
            &self.root,
            &["rev-parse".into(), "--absolute-git-dir".into()],
            policy,
            cancellation,
        )?;
        if output_path(&actual.stdout)? != self.git_dir {
            return Err(Error::StaleRepository);
        }
        Ok(())
    }
    fn read(
        &self,
        arguments: &[OsString],
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<GitOutput, Error> {
        self.verify(policy, cancellation)?;
        self.git
            .checked(&self.root, arguments, policy, cancellation)
    }
    pub fn status(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<ReadResult<Status>, Error> {
        let output = self.read(
            &[
                "--no-optional-locks".into(),
                "status".into(),
                "--porcelain=v2".into(),
                "--branch".into(),
                "--untracked-files=all".into(),
                "-z".into(),
            ],
            policy,
            cancellation,
        )?;
        Ok(ReadResult {
            value: parse_status(&output.stdout)?,
            output,
        })
    }
    pub fn diff(
        &self,
        target: DiffTarget,
        path: Option<&RepoPath>,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<GitOutput, Error> {
        let mut arguments: Vec<OsString> = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
            .into_iter()
            .map(Into::into)
            .collect();
        if matches!(target, DiffTarget::Index) {
            arguments.push("--cached".into());
        }
        arguments.push("--".into());
        if let Some(path) = path {
            arguments.push(path.argument());
        }
        self.read(&arguments, policy, cancellation)
    }
    /// Roher, begrenzter Verlauf wie im bestehenden Git-Text-Tab.
    pub fn log(
        &self,
        count: u32,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<GitOutput, Error> {
        if count == 0 || count > 10_000 {
            return Err(Error::InvalidInput("invalid log count"));
        }
        self.read(
            &[
                "log".into(),
                "--graph".into(),
                "--oneline".into(),
                "--decorate".into(),
                "--all".into(),
                "--no-color".into(),
                format!("-{count}").into(),
                "--".into(),
            ],
            policy,
            cancellation,
        )
    }
    pub fn branches(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<ReadResult<Vec<Branch>>, Error> {
        let output = self.read(
            &[
                "for-each-ref".into(),
                "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(worktreepath)%00".into(),
                "--sort=refname".into(),
                "refs/heads".into(),
                "refs/remotes".into(),
            ],
            policy,
            cancellation,
        )?;
        Ok(ReadResult {
            value: parse_branches(&output.stdout)?,
            output,
        })
    }
}
pub(crate) fn check_oid(value: &[u8]) -> Result<(), Error> {
    if !matches!(value.len(), 40 | 64) || !value.iter().all(u8::is_ascii_hexdigit) {
        return Err(Error::MalformedOutput("invalid object ID"));
    }
    Ok(())
}
fn parse_branches(output: &[u8]) -> Result<Vec<Branch>, Error> {
    let mut remaining = output;
    let mut branches = Vec::new();
    while !remaining.is_empty() {
        let mut fields = Vec::new();
        for _ in 0..4 {
            let end = remaining
                .iter()
                .position(|b| *b == 0)
                .ok_or(Error::MalformedOutput("unterminated branch field"))?;
            fields.push(&remaining[..end]);
            remaining = &remaining[end + 1..];
        }
        if !remaining.starts_with(b"\n") {
            return Err(Error::MalformedOutput("missing branch terminator"));
        }
        remaining = &remaining[1..];
        if !(fields[0].starts_with(b"refs/heads/") || fields[0].starts_with(b"refs/remotes/"))
            || fields[0].contains(&b'\n')
        {
            return Err(Error::MalformedOutput("invalid branch ref"));
        }
        check_oid(fields[1])?;
        if fields[2] != b"*" && fields[2] != b" " {
            return Err(Error::MalformedOutput("invalid current branch marker"));
        }
        branches.push(Branch {
            full_name: fields[0].to_vec(),
            oid: fields[1].to_vec(),
            current: fields[2] == b"*",
            worktree_path: fields[3].to_vec(),
        });
    }
    Ok(branches)
}
