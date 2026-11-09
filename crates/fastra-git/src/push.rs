//! Manueller Push mit unveränderlicher Quelle, gebundener Adresse und exakter Remote-Lease.
use crate::*;
use std::time::Instant;

#[derive(Clone, PartialEq, Eq)]
pub struct PushTarget {
    remote: Vec<u8>,
    address: Vec<u8>,
}
impl std::fmt::Debug for PushTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushTarget")
            .field("remote", &self.remote)
            .field("address", &self.address_display())
            .finish()
    }
}
impl PushTarget {
    pub fn remote(&self) -> &[u8] {
        &self.remote
    }
    /// Anzeige ausschließlich ohne eingebettete Zugangsdaten verwenden.
    pub fn address_display(&self) -> String {
        let value = String::from_utf8_lossy(&self.address);
        if let Some((scheme, rest)) = value.split_once("://") {
            let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
            let authority = &rest[..end];
            let authority = authority
                .rsplit_once('@')
                .map_or(authority.to_owned(), |(_, host)| format!("•••@{host}"));
            let tail = &rest[end..];
            let end = tail.find(['?', '#']).unwrap_or(tail.len());
            format!(
                "{scheme}://{authority}{}{}",
                &tail[..end],
                if end < tail.len() { "…" } else { "" }
            )
        } else {
            value.into_owned()
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PushMode {
    Normal,
    ForceWithLease,
}
#[derive(Debug)]
pub struct PushPreview {
    repository: Repository,
    identity: (u64, u64),
    target: PushTarget,
    branch: Vec<u8>,
    source_oid: Vec<u8>,
    remote_ref: Vec<u8>,
    remote_oid: Option<Vec<u8>>,
    ahead: u64,
    behind: u64,
    commits: GitOutput,
    removed_commits: GitOutput,
    mode: PushMode,
}
impl PushPreview {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn target(&self) -> &PushTarget {
        &self.target
    }
    pub fn branch(&self) -> &[u8] {
        &self.branch
    }
    pub fn source_oid(&self) -> &[u8] {
        &self.source_oid
    }
    pub fn remote_ref(&self) -> &[u8] {
        &self.remote_ref
    }
    pub fn remote_oid(&self) -> Option<&[u8]> {
        self.remote_oid.as_deref()
    }
    pub fn ahead(&self) -> u64 {
        self.ahead
    }
    pub fn behind(&self) -> u64 {
        self.behind
    }
    pub fn commits(&self) -> &GitOutput {
        &self.commits
    }
    /// Vollständige Commits, die nach dem Update über diesen Zielbranch nicht mehr erreichbar sind.
    pub fn removed_commits(&self) -> &GitOutput {
        &self.removed_commits
    }
    pub fn force_with_lease(&self) -> bool {
        self.mode == PushMode::ForceWithLease
    }
    pub fn can_push(&self) -> bool {
        match self.mode {
            PushMode::Normal => self.behind == 0 && (self.remote_oid.is_none() || self.ahead > 0),
            PushMode::ForceWithLease => self
                .remote_oid
                .as_ref()
                .is_some_and(|old| old != &self.source_oid),
        }
    }
}
struct Budget {
    start: Instant,
    policy: Policy,
}
impl Budget {
    fn new(policy: Policy) -> Self {
        Self {
            start: Instant::now(),
            policy,
        }
    }
    fn policy(&self) -> Result<Policy, Error> {
        let timeout = self.policy.timeout.saturating_sub(self.start.elapsed());
        if timeout.is_zero() {
            return Err(Error::TimedOut(GitOutput::empty()));
        }
        Ok(Policy {
            timeout,
            ..self.policy
        })
    }
}
fn line(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    let value = bytes
        .strip_suffix(b"\n")
        .ok_or(Error::MalformedOutput("unterminated push value"))?;
    if value.is_empty() || value.contains(&b'\n') || value.contains(&0) || value.contains(&b'\r') {
        return Err(Error::MalformedOutput("ambiguous push value"));
    }
    Ok(value.to_vec())
}
fn network_environment() -> fastra_process::Environment {
    fastra_process::Environment {
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
            ("GIT_NO_REPLACE_OBJECTS", "1"),
            ("GIT_GRAFT_FILE", "/dev/null"),
        ]
        .into_iter()
        .map(|(k, v)| (k.into(), v.into()))
        .collect(),
    }
}
/// Wie im Mac-Vertrag: die exakte zufällige Sentinelregel wird nur einmal
/// umgeschrieben. Später ergänzte breite URL-Regeln können das Ziel nicht umlenken.
fn bound_call(
    repo: &Repository,
    target: &PushTarget,
    args: &[OsString],
    budget: &Budget,
    cancel: &Cancellation,
    observer: &mut dyn FnMut(&[u8]),
) -> Result<GitOutput, Error> {
    let nonce = tempfile::Builder::new()
        .prefix("fastra-push-")
        .rand_bytes(24)
        .tempdir()
        .map_err(|e| Error::Io(e.to_string()))?;
    let name = nonce.path().file_name().unwrap().to_string_lossy();
    let remote = format!("fastra-bound-{name}");
    let sentinel = format!("{remote}://target");
    let mut env = network_environment();
    let mut url_key = b"url.".to_vec();
    url_key.extend_from_slice(&target.address);
    url_key.extend_from_slice(b".insteadOf");
    let entries: Vec<(OsString, OsString)> = vec![
        (
            format!("remote.{remote}.url").into(),
            sentinel.clone().into(),
        ),
        (
            format!("remote.{remote}.pushurl").into(),
            sentinel.clone().into(),
        ),
        (OsString::from_vec(url_key), sentinel.into()),
    ];
    env.set
        .push(("GIT_CONFIG_COUNT".into(), entries.len().to_string().into()));
    for (index, (key, value)) in entries.into_iter().enumerate() {
        env.set
            .push((format!("GIT_CONFIG_KEY_{index}").into(), key));
        env.set
            .push((format!("GIT_CONFIG_VALUE_{index}").into(), value));
    }
    let mut all: Vec<OsString> = [
        "--no-pager",
        "--no-replace-objects",
        "-c",
        "color.ui=false",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "maintenance.auto=false",
        "-c",
        "advice.graftFileDeprecated=false",
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    // Der Platzhalter wird nur in selbst erzeugten Argumenten ersetzt, nie in Nutzerdaten.
    all.extend(args.iter().map(|a| {
        if a == "@BOUND_REMOTE@" {
            remote.clone().into()
        } else {
            a.clone()
        }
    }));
    let out = fastra_process::run_with_stderr(
        &repo.git.executable,
        &repo.root,
        &all,
        budget.policy()?,
        cancel,
        &env,
        fastra_process::ParentLoss::Terminate,
        observer,
    )?;
    if out.success() {
        Ok(out)
    } else {
        Err(Error::GitFailed(out))
    }
}
impl Repository {
    fn push_read(
        &self,
        arguments: &[OsString],
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<GitOutput, Error> {
        self.verify(policy, cancel)?;
        let mut all: Vec<OsString> = ["-c", "advice.graftFileDeprecated=false"]
            .into_iter()
            .map(Into::into)
            .collect();
        all.extend_from_slice(arguments);
        self.git.checked_env(
            &self.root,
            &all,
            policy,
            cancel,
            &[("GIT_GRAFT_FILE".into(), "/dev/null".into())],
        )
    }
    pub fn push_target(
        &self,
        remote: &[u8],
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<PushTarget, Error> {
        let budget = Budget::new(policy);
        if !self
            .remotes(budget.policy()?, cancel)?
            .value
            .iter()
            .any(|r| r == remote)
        {
            return Err(Error::StalePreview);
        }
        let output = self.push_read(
            &[
                "remote".into(),
                "get-url".into(),
                "--push".into(),
                "--all".into(),
                "--".into(),
                OsString::from_vec(remote.to_vec()),
            ],
            budget.policy()?,
            cancel,
        )?;
        let address = line(&output.stdout)
            .map_err(|_| Error::InvalidInput("Push requires exactly one address per remote"))?;
        Ok(PushTarget {
            remote: remote.to_vec(),
            address,
        })
    }
    pub fn push_targets(
        &self,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<Vec<PushTarget>, Error> {
        let budget = Budget::new(policy);
        self.remotes(budget.policy()?, cancel)?
            .value
            .iter()
            .map(|remote| self.push_target(remote, budget.policy()?, cancel))
            .collect()
    }
    fn push_head(
        &self,
        budget: &Budget,
        cancel: &Cancellation,
    ) -> Result<(Vec<u8>, Vec<u8>), Error> {
        let branch = line(
            &self
                .push_read(
                    &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
                    budget.policy()?,
                    cancel,
                )?
                .stdout,
        )?;
        if !branch.starts_with(b"refs/heads/") {
            return Err(Error::InvalidInput("push requires a local branch"));
        }
        let oid = line(
            &self
                .push_read(
                    &[
                        "--no-replace-objects".into(),
                        "rev-parse".into(),
                        "--verify".into(),
                        "HEAD^{commit}".into(),
                    ],
                    budget.policy()?,
                    cancel,
                )?
                .stdout,
        )?;
        check_oid(&oid)?;
        Ok((branch, oid))
    }
    fn check_push_target(
        &self,
        target: &PushTarget,
        budget: &Budget,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        if self.push_target(&target.remote, budget.policy()?, cancel)? != *target {
            return Err(Error::StalePreview);
        }
        match self.push_read(
            &[
                "config".into(),
                "--includes".into(),
                "--get-regexp".into(),
                "^url\\..*\\.(insteadof|pushinsteadof)$".into(),
            ],
            budget.policy()?,
            cancel,
        ) {
            Err(Error::GitFailed(out)) if out.exit_code == Some(1) && out.stdout.is_empty() => {
                Ok(())
            }
            Ok(out) if out.stdout.is_empty() => Ok(()),
            Ok(_) => Err(Error::InvalidInput(
                "Git URL rewrite rules prevent an unambiguous push target",
            )),
            Err(e) => Err(e),
        }
    }
    /// Erreichbarkeitsprüfung und exakter Objektabruf erst nach ausdrücklicher Vorschau-Aktion.
    pub fn prepare_push(
        &self,
        target: &PushTarget,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<PushPreview, Error> {
        self.prepare_push_mode(target, PushMode::Normal, policy, cancel, observer)
    }
    /// Eigene ausdrückliche Freigabe: niemals aus einer normalen Vorschau ableiten.
    pub fn prepare_force_push(
        &self,
        target: &PushTarget,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<PushPreview, Error> {
        self.prepare_push_mode(target, PushMode::ForceWithLease, policy, cancel, observer)
    }
    fn require_full_push_history(
        &self,
        budget: &Budget,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        let out = self.push_read(
            &["rev-parse".into(), "--is-shallow-repository".into()],
            budget.policy()?,
            cancel,
        )?;
        if out.stdout != b"false\n" {
            return Err(Error::InvalidInput(
                "force push requires complete non-shallow history",
            ));
        }
        Ok(())
    }
    fn prepare_push_mode(
        &self,
        target: &PushTarget,
        mode: PushMode,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<PushPreview, Error> {
        let budget = Budget::new(policy);
        let _lease = self.try_operation()?;
        let identity = self.operation_identity()?;
        if mode == PushMode::ForceWithLease {
            self.require_full_push_history(&budget, cancel)?;
        }
        self.verify(budget.policy()?, cancel)?;
        self.check_push_target(target, &budget, cancel)?;
        let (branch, source_oid) = self.push_head(&budget, cancel)?;
        let remote_ref = branch.clone();
        let args = [
            "ls-remote".into(),
            "--exit-code".into(),
            "--refs".into(),
            "--".into(),
            "@BOUND_REMOTE@".into(),
            OsString::from_vec(remote_ref.clone()),
        ];
        let remote_oid = match bound_call(self, target, &args, &budget, cancel, observer) {
            Err(Error::GitFailed(out)) if out.exit_code == Some(2) && out.stdout.is_empty() => None,
            Ok(out) => {
                let record = line(&out.stdout)?;
                let (oid, name) = record.split_at(
                    record
                        .iter()
                        .position(|b| *b == b'\t')
                        .ok_or(Error::MalformedOutput("push remote OID"))?,
                );
                check_oid(oid)?;
                if name[1..] != remote_ref {
                    return Err(Error::MalformedOutput("push remote ref"));
                }
                Some(oid.to_vec())
            }
            Err(e) => return Err(e),
        };
        if mode == PushMode::ForceWithLease
            && remote_oid.as_ref().is_none_or(|old| old == &source_oid)
        {
            return Err(Error::InvalidInput(
                "force push requires an existing different target commit",
            ));
        }
        if let Some(old) = &remote_oid {
            bound_call(
                self,
                target,
                &[
                    "fetch".into(),
                    "--no-tags".into(),
                    "--no-write-fetch-head".into(),
                    "--no-prune".into(),
                    "--no-prune-tags".into(),
                    "--no-write-commit-graph".into(),
                    "--no-recurse-submodules".into(),
                    "--no-auto-maintenance".into(),
                    "--".into(),
                    "@BOUND_REMOTE@".into(),
                    OsString::from_vec(old.clone()),
                ],
                &budget,
                cancel,
                observer,
            )?;
        }
        let (mut ahead, behind) = if let Some(old) = &remote_oid {
            let range = format!(
                "{}...{}",
                String::from_utf8_lossy(&source_oid),
                String::from_utf8_lossy(old)
            );
            let out = self.push_read(
                &[
                    "--no-replace-objects".into(),
                    "rev-list".into(),
                    "--left-right".into(),
                    "--count".into(),
                    range.into(),
                ],
                budget.policy()?,
                cancel,
            )?;
            let values: Vec<_> = out
                .stdout
                .split(u8::is_ascii_whitespace)
                .filter(|v| !v.is_empty())
                .collect();
            if values.len() != 2 {
                return Err(Error::MalformedOutput("push counts"));
            }
            let count = |v: &[u8]| {
                std::str::from_utf8(v)
                    .ok()
                    .and_then(|v| v.parse::<u64>().ok())
                    .ok_or(Error::MalformedOutput("push count"))
            };
            (count(values[0])?, count(values[1])?)
        } else {
            (0, 0)
        };
        let mut args: Vec<OsString> = [
            "--no-replace-objects",
            "log",
            "--format=%H %s",
            "--no-color",
            "--no-decorate",
        ]
        .into_iter()
        .map(Into::into)
        .collect();
        args.push(OsString::from_vec(source_oid.clone()));
        if let Some(old) = &remote_oid {
            let mut arg = vec![b'^'];
            arg.extend_from_slice(old);
            args.push(OsString::from_vec(arg));
        }
        args.push("--".into());
        let commits = self.push_read(&args, budget.policy()?, cancel)?;
        if remote_oid.is_none() {
            ahead = commits
                .stdout
                .split(|b| *b == b'\n')
                .filter(|line| !line.is_empty())
                .count() as u64;
        }
        let removed_commits = if mode == PushMode::ForceWithLease {
            self.require_full_push_history(&budget, cancel)?;
            let old = remote_oid.as_ref().ok_or(Error::StalePreview)?;
            let out = self.push_read(
                &[
                    "--no-replace-objects".into(),
                    "log".into(),
                    "--format=%H %s".into(),
                    "--no-color".into(),
                    "--no-decorate".into(),
                    OsString::from_vec(old.clone()),
                    OsString::from_vec([b"^".as_slice(), source_oid.as_slice()].concat()),
                    "--".into(),
                ],
                budget.policy()?,
                cancel,
            )?;
            let count = |out: &GitOutput| {
                out.stdout
                    .split(|b| *b == b'\n')
                    .filter(|line| !line.is_empty())
                    .count() as u64
            };
            if count(&commits) != ahead || count(&out) != behind {
                return Err(Error::MalformedOutput("incomplete force push commit lists"));
            }
            out
        } else {
            GitOutput::empty()
        };
        if self.operation_identity()? != identity
            || self.push_head(&budget, cancel)? != (branch.clone(), source_oid.clone())
        {
            return Err(Error::StalePreview);
        }
        Ok(PushPreview {
            repository: self.clone(),
            identity,
            target: target.clone(),
            branch,
            source_oid,
            remote_ref,
            remote_oid,
            ahead,
            behind,
            commits,
            removed_commits,
            mode,
        })
    }
}
impl PushPreview {
    pub fn execute(
        &self,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<GitOutput, Error> {
        let budget = Budget::new(policy);
        let repo = &self.repository;
        let _lease = repo.try_operation()?;
        if repo.operation_identity()? != self.identity {
            return Err(Error::StaleRepository);
        }
        repo.verify(budget.policy()?, cancel)?;
        repo.check_push_target(&self.target, &budget, cancel)?;
        if repo.push_head(&budget, cancel)? != (self.branch.clone(), self.source_oid.clone()) {
            return Err(Error::StalePreview);
        }
        if self.force_with_lease() {
            repo.require_full_push_history(&budget, cancel)?;
        }
        if !self.can_push() {
            return Err(Error::InvalidInput(
                "normal push requires new commits and a fast-forward",
            ));
        }
        // CAS allein erlaubt auch nicht-FF. Die echte Objekt-Abstammung muss unabhängig stimmen.
        if let Some(old) = self
            .remote_oid
            .as_ref()
            .filter(|_| !self.force_with_lease())
        {
            let extra = [("GIT_GRAFT_FILE".into(), "/dev/null".into())];
            repo.git.checked_env(
                &repo.root,
                &[
                    "-c".into(),
                    "advice.graftFileDeprecated=false".into(),
                    "--no-replace-objects".into(),
                    "merge-base".into(),
                    "--is-ancestor".into(),
                    OsString::from_vec(old.clone()),
                    OsString::from_vec(self.source_oid.clone()),
                ],
                budget.policy()?,
                cancel,
                &extra,
            )?;
        }
        let expected = self.remote_oid.as_deref().unwrap_or_default();
        let mut lease = b"--force-with-lease=".to_vec();
        lease.extend_from_slice(&self.remote_ref);
        lease.push(b':');
        lease.extend_from_slice(expected);
        let mut refspec = self.source_oid.clone();
        refspec.push(b':');
        refspec.extend_from_slice(&self.remote_ref);
        bound_call(
            repo,
            &self.target,
            &[
                "push".into(),
                "--porcelain".into(),
                "--progress".into(),
                "--no-follow-tags".into(),
                "--recurse-submodules=no".into(),
                OsString::from_vec(lease),
                "--".into(),
                "@BOUND_REMOTE@".into(),
                OsString::from_vec(refspec),
            ],
            &budget,
            cancel,
            observer,
        )
    }
}
#[cfg(test)]
mod tests;
