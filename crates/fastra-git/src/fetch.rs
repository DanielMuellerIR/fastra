//! Expliziter Fetch; lesende APIs behalten ihre netzwerkfreie Umgebung.
use crate::*;
use std::{
    collections::HashSet,
    sync::{Mutex, OnceLock},
    time::Instant,
};

const MAX_REMOTES: usize = 64;
type OperationKey = (u64, u64);
fn operations() -> &'static Mutex<HashSet<OperationKey>> {
    static ACTIVE: OnceLock<Mutex<HashSet<OperationKey>>> = OnceLock::new();
    ACTIVE.get_or_init(Default::default)
}
/// Prozessweite Koordination auch zwischen mehreren Fenstern desselben Repositorys.
pub struct OperationLease(OperationKey);
impl Drop for OperationLease {
    fn drop(&mut self) {
        operations()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.0);
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchSelection {
    All,
    Remote(Vec<u8>),
}
#[derive(Debug, Clone)]
pub struct FetchPlan {
    repository: Repository,
    identity: (u64, u64),
    remotes: Vec<Vec<u8>>,
    prune: bool,
}
#[derive(Debug)]
pub struct RemoteFetch {
    pub remote: Vec<u8>,
    pub result: Result<GitOutput, Error>,
}
#[derive(Debug)]
pub struct FetchReport {
    pub attempts: Vec<RemoteFetch>,
    pub remaining: Vec<Vec<u8>>,
}
impl FetchReport {
    pub fn success(&self) -> bool {
        self.remaining.is_empty() && self.attempts.iter().all(|r| r.result.is_ok())
    }
}
impl Repository {
    /// Dateisystemzugriff: wie alle Repository-Operationen ausschließlich auf einem Worker.
    pub fn operation_identity(&self) -> Result<(u64, u64), Error> {
        use std::{
            io::Read,
            os::{
                fd::{AsRawFd, FromRawFd},
                unix::fs::OpenOptionsExt,
            },
        };
        let directory = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&self.git_dir)
            .map_err(|_| Error::StaleRepository)?;
        let metadata = directory.metadata().map_err(|_| Error::StaleRepository)?;
        if !metadata.is_dir() || (metadata.dev(), metadata.ino()) != self.git_identity {
            return Err(Error::StaleRepository);
        }
        // Der gehaltene Ordner bindet den Namen; O_NONBLOCK verhindert ein Warten auf fremde FIFOs.
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                c"commondir".as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
                Ok(self.git_identity)
            } else {
                Err(Error::StaleRepository)
            };
        }
        let mut common = unsafe { fs::File::from_raw_fd(fd) };
        let metadata = common.metadata().map_err(|_| Error::StaleRepository)?;
        if !metadata.is_file() {
            return Err(Error::StaleRepository);
        }
        if metadata.len() > 4096 {
            return Err(Error::InvalidInput("Git common-directory path limit"));
        }
        let mut bytes = Vec::new();
        common
            .by_ref()
            .take(4097)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::StaleRepository)?;
        if bytes.len() > 4096 {
            return Err(Error::InvalidInput("Git common-directory path limit"));
        }
        if bytes.last() == Some(&b'\n') {
            bytes.pop();
        }
        if bytes.is_empty() || bytes.contains(&0) {
            return Err(Error::StaleRepository);
        }
        let path = std::ffi::CString::new(bytes).map_err(|_| Error::StaleRepository)?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(Error::StaleRepository);
        }
        let target = unsafe { fs::File::from_raw_fd(fd) };
        let metadata = target.metadata().map_err(|_| Error::StaleRepository)?;
        if !metadata.is_dir() {
            return Err(Error::StaleRepository);
        }
        Ok((metadata.dev(), metadata.ino()))
    }
    pub fn try_operation(&self) -> Result<OperationLease, Error> {
        let key = self.operation_identity()?;
        let mut active = operations().lock().unwrap_or_else(|e| e.into_inner());
        if !active.insert(key) {
            return Err(Error::InvalidInput(
                "another repository operation is running",
            ));
        }
        Ok(OperationLease(key))
    }
    /// Konfigurierte Namen als Bytes; weder URL-Eingabe noch Gruppennamen-Auflösung.
    pub fn remotes(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<ReadResult<Vec<Vec<u8>>>, Error> {
        self.verify(policy, cancellation)?;
        let output = match self.git.checked(
            &self.root,
            &[
                "config".into(),
                "--null".into(),
                "--name-only".into(),
                "--get-regexp".into(),
                "^remote\\..*\\.url$".into(),
            ],
            policy,
            cancellation,
        ) {
            Ok(out) => out,
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) && out.stdout.is_empty() => out,
            Err(e) => return Err(e),
        };
        let mut names = Vec::new();
        for key in output.stdout.split(|b| *b == 0).filter(|b| !b.is_empty()) {
            let name = key
                .strip_prefix(b"remote.")
                .and_then(|k| k.strip_suffix(b".url"))
                .ok_or(Error::MalformedOutput("remote configuration key"))?;
            if name.is_empty() || name.contains(&b'\n') || name.contains(&b'\r') {
                return Err(Error::InvalidInput("unsupported configured remote name"));
            }
            if !names.iter().any(|n| n == name) {
                names.push(name.to_vec());
            }
            if names.len() > MAX_REMOTES {
                return Err(Error::InvalidInput("remote limit: 64"));
            }
        }
        names.sort();
        Ok(ReadResult {
            value: names,
            output,
        })
    }
    pub fn prepare_fetch(
        &self,
        selection: FetchSelection,
        prune: bool,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<FetchPlan, Error> {
        let configured = self.remotes(policy, cancellation)?.value;
        let remotes = match selection {
            FetchSelection::All => configured,
            FetchSelection::Remote(remote) if configured.contains(&remote) => vec![remote],
            FetchSelection::Remote(_) => {
                return Err(Error::InvalidInput("remote is no longer configured"))
            }
        };
        if remotes.is_empty() {
            return Err(Error::InvalidInput("no remote configured"));
        }
        Ok(FetchPlan {
            repository: self.clone(),
            identity: self.operation_identity()?,
            remotes,
            prune,
        })
    }
}
impl FetchPlan {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn remotes(&self) -> &[Vec<u8>] {
        &self.remotes
    }
    pub fn prune(&self) -> bool {
        self.prune
    }
    /// Gesamtfrist und Gesamt-Ausgabegrenzen gelten über alle Einzelaufrufe hinweg.
    /// Der Observer erhält nur akzeptierte stderr-Bytes und darf nicht blockieren.
    pub fn execute(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
        observer: &mut dyn FnMut(&[u8], &[u8]),
    ) -> Result<FetchReport, Error> {
        let repo = &self.repository;
        let started = Instant::now();
        let remaining_policy = || {
            let timeout = policy.timeout.saturating_sub(started.elapsed());
            if timeout.is_zero() {
                return Err(Error::TimedOut(GitOutput::empty()));
            }
            Ok(Policy { timeout, ..policy })
        };
        let _lease = repo.try_operation()?;
        if repo.operation_identity()? != self.identity {
            return Err(Error::StaleRepository);
        }
        repo.verify(remaining_policy()?, cancellation)?;
        let configured = repo.remotes(remaining_policy()?, cancellation)?.value;
        if self.remotes.iter().any(|r| !configured.contains(r)) {
            return Err(Error::InvalidInput("remote is no longer configured"));
        }
        let mut report = FetchReport {
            attempts: Vec::new(),
            remaining: self.remotes.clone(),
        };
        let mut stdout_left = policy.stdout_bytes;
        let mut stderr_left = policy.stderr_bytes;
        for remote in &self.remotes {
            if let Err(error) = remaining_policy()
                .and_then(|policy| repo.verify(policy, cancellation))
                .and_then(|()| {
                    if repo.operation_identity()? == self.identity {
                        Ok(())
                    } else {
                        Err(Error::StaleRepository)
                    }
                })
            {
                report.remaining.remove(0);
                report.attempts.push(RemoteFetch {
                    remote: remote.clone(),
                    result: Err(error),
                });
                break;
            }
            if cancellation.is_cancelled()
                || started.elapsed() >= policy.timeout
                || stdout_left == 0
                || stderr_left == 0
            {
                break;
            }
            let call_policy = Policy {
                timeout: policy.timeout.saturating_sub(started.elapsed()),
                stdout_bytes: stdout_left,
                stderr_bytes: stderr_left,
                ..policy
            };
            let mut arguments: Vec<OsString> = [
                "--no-pager",
                "-c",
                "color.ui=false",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "maintenance.auto=false",
                "fetch",
                "--progress",
                "--no-recurse-submodules",
                "--no-auto-maintenance",
            ]
            .into_iter()
            .map(Into::into)
            .collect();
            arguments.push(if self.prune { "--prune" } else { "--no-prune" }.into());
            arguments.push("--".into());
            arguments.push(OsString::from_vec(remote.clone()));
            let environment = fastra_process::Environment {
                remove_prefixes: vec!["GIT_".into()],
                set: [
                    ("GIT_TERMINAL_PROMPT", "0"),
                    ("GIT_NO_LAZY_FETCH", "1"),
                    ("GIT_ALLOW_PROTOCOL", "file:ssh:https:http:git"),
                    ("GIT_ASKPASS", "/usr/bin/false"),
                    ("SSH_ASKPASS", "/usr/bin/false"),
                    ("SSH_ASKPASS_REQUIRE", "never"),
                    (
                        "GIT_SSH_COMMAND",
                        "ssh -oBatchMode=yes -oStrictHostKeyChecking=yes",
                    ),
                    ("GIT_EDITOR", "/usr/bin/false"),
                ]
                .into_iter()
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
            };
            let result = fastra_process::run_with_stderr(
                &repo.git.executable,
                &repo.root,
                &arguments,
                call_policy,
                cancellation,
                &environment,
                fastra_process::ParentLoss::Terminate,
                &mut |bytes| observer(remote, bytes),
            )
            .map_err(Error::from)
            .and_then(|out| {
                if out.success() {
                    Ok(out)
                } else {
                    Err(Error::GitFailed(out))
                }
            });
            let out = match &result {
                Ok(o)
                | Err(
                    Error::GitFailed(o)
                    | Error::Cancelled(o)
                    | Error::TimedOut(o)
                    | Error::OutputLimit(o)
                    | Error::Capture { output: o, .. },
                ) => Some(o),
                _ => None,
            };
            if let Some(out) = out {
                stdout_left = stdout_left.saturating_sub(out.stdout.len());
                stderr_left = stderr_left.saturating_sub(out.stderr.len());
            }
            let stop = matches!(
                result,
                Err(Error::Cancelled(_)
                    | Error::TimedOut(_)
                    | Error::OutputLimit(_)
                    | Error::Capture { .. }
                    | Error::Launch(_)
                    | Error::Unavailable)
            );
            report.remaining.remove(0);
            report.attempts.push(RemoteFetch {
                remote: remote.clone(),
                result,
            });
            if stop {
                break;
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests;
