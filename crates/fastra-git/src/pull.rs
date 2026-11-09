//! Bewusster nativer Pull mit vollständigen Commit-Patches und verbrauchter Freigabe.
use crate::{switch::Budget, *};
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullStrategy {
    FastForwardOnly,
    Merge,
    Rebase,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullState {
    pub files: SwitchState,
    pub operations: Vec<String>,
    pub fetched_oid: Option<Vec<u8>>,
}
pub struct PullPreview {
    repository: Repository,
    identity: (u64, u64),
    remote: Vec<u8>,
    branch: Vec<u8>,
    address: Vec<u8>,
    strategy: PullStrategy,
    source: PullState,
    config: Vec<u8>,
    refs: Vec<u8>,
    hooks: Vec<u8>,
    hook_dir: PathBuf,
    bindings: mutation::SwitchBindings,
    incoming: GitOutput,
    local: GitOutput,
    delta: GitOutput,
}
impl std::fmt::Debug for PullPreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PullPreview")
            .field("strategy", &self.strategy)
            .finish_non_exhaustive()
    }
}
fn args(v: &[&str]) -> Vec<OsString> {
    v.iter().map(Into::into).collect()
}
fn line(v: &[u8]) -> Result<Vec<u8>, Error> {
    let v = v
        .strip_suffix(b"\n")
        .ok_or(Error::MalformedOutput("pull value"))?;
    if v.is_empty() || v.iter().any(|b| matches!(b, 0 | 10 | 13)) {
        return Err(Error::InvalidInput("ambiguous pull value"));
    }
    Ok(v.to_vec())
}
fn environment() -> fastra_process::Environment {
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
            ("GIT_SEQUENCE_EDITOR", "/usr/bin/false"),
            ("GIT_MERGE_AUTOEDIT", "no"),
            ("GIT_NO_REPLACE_OBJECTS", "1"),
            ("GIT_GRAFT_FILE", "/dev/null"),
        ]
        .into_iter()
        .map(|(k, v)| (k.into(), v.into()))
        .collect(),
    }
}
fn clean_address(value: &[u8]) -> Vec<u8> {
    let Some(scheme) = value.windows(3).position(|v| v == b"://") else {
        return value.to_vec();
    };
    let authority = scheme + 3;
    let end = value[authority..]
        .iter()
        .position(|b| matches!(b, b'/' | b'?' | b'#'))
        .map_or(value.len(), |p| authority + p);
    let host = value[authority..end]
        .iter()
        .rposition(|b| *b == b'@')
        .map_or(authority, |p| authority + p + 1);
    let tail_end = value[end..]
        .iter()
        .position(|b| matches!(b, b'?' | b'#'))
        .map_or(value.len(), |p| end + p);
    let mut clean = value[..authority].to_vec();
    clean.extend_from_slice(&value[host..end]);
    clean.extend_from_slice(&value[end..tail_end]);
    if tail_end < value.len() {
        clean.extend_from_slice("…".as_bytes());
    }
    clean
}
fn address_display(address: &[u8]) -> String {
    let clean = clean_address(address);
    match String::from_utf8(clean) {
        Ok(value) => value,
        Err(error) => error
            .as_bytes()
            .iter()
            .flat_map(|b| std::ascii::escape_default(*b))
            .map(char::from)
            .collect(),
    }
}
fn redact_bytes(value: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut offset = 0;
    while let Some(found) = value[offset..].windows(3).position(|v| v == b"://") {
        let colon = offset + found;
        let mut start = colon;
        while start > offset
            && (value[start - 1].is_ascii_alphanumeric()
                || matches!(value[start - 1], b'+' | b'-' | b'.'))
        {
            start -= 1;
        }
        if start == colon {
            out.extend_from_slice(&value[offset..colon + 3]);
            offset = colon + 3;
            continue;
        }
        let end = value[colon + 3..]
            .iter()
            .position(|b| b.is_ascii_whitespace() || matches!(b, b'\'' | b'"' | b'<' | b'>'))
            .map_or(value.len(), |p| colon + 3 + p);
        out.extend_from_slice(&value[offset..start]);
        let token = &value[start..end];
        if end == value.len()
            && !value[colon + 3..end]
                .iter()
                .any(|b| matches!(b, b'/' | b'?' | b'#' | b'@'))
        {
            out.extend_from_slice(&value[start..colon + 3]);
            out.extend_from_slice(b"[redacted]");
        } else {
            out.extend_from_slice(&clean_address(token));
        }
        offset = end;
    }
    out.extend_from_slice(&value[offset..]);
    out
}
fn redact(out: &mut GitOutput) {
    out.stdout = redact_bytes(&out.stdout);
    out.stderr = redact_bytes(&out.stderr);
}
fn redact_error(e: Error) -> Error {
    match e {
        Error::Launch(message) => {
            Error::Launch(String::from_utf8_lossy(&redact_bytes(message.as_bytes())).into_owned())
        }
        Error::Io(message) => {
            Error::Io(String::from_utf8_lossy(&redact_bytes(message.as_bytes())).into_owned())
        }
        Error::IndexPublished(message) => Error::IndexPublished(
            String::from_utf8_lossy(&redact_bytes(message.as_bytes())).into_owned(),
        ),
        Error::GitFailed(mut out) => {
            redact(&mut out);
            Error::GitFailed(out)
        }
        Error::Cancelled(mut out) => {
            redact(&mut out);
            Error::Cancelled(out)
        }
        Error::TimedOut(mut out) => {
            redact(&mut out);
            Error::TimedOut(out)
        }
        Error::OutputLimit(mut out) => {
            redact(&mut out);
            Error::OutputLimit(out)
        }
        Error::Capture {
            message,
            mut output,
        } => {
            redact(&mut output);
            Error::Capture {
                message: String::from_utf8_lossy(&redact_bytes(message.as_bytes())).into_owned(),
                output,
            }
        }
        e => e,
    }
}
fn call(
    r: &Repository,
    a: Vec<OsString>,
    b: &mut Budget,
    c: &Cancellation,
    o: &mut dyn FnMut(&[u8]),
) -> Result<GitOutput, Error> {
    let mut all = args(&[
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
    ]);
    all.extend(a);
    let mut line = Vec::new();
    let result = fastra_process::run_with_stderr(
        &r.git.executable,
        &r.root,
        &all,
        b.policy()?,
        c,
        &environment(),
        fastra_process::ParentLoss::Terminate,
        &mut |bytes| {
            for byte in bytes {
                line.push(*byte);
                if matches!(byte, b'\r' | b'\n') {
                    o(&redact_bytes(&line));
                    line.clear();
                }
            }
        },
    );
    if !line.is_empty() {
        o(&redact_bytes(&line));
    }
    let mut out = result.map_err(|e| redact_error(e.into()))?;
    redact(&mut out);
    b.consume(&out);
    if out.success() {
        Ok(out)
    } else {
        Err(Error::GitFailed(out))
    }
}
impl Budget {
    fn pull_command(
        &mut self,
        repo: &Repository,
        args: Vec<OsString>,
        cancel: &Cancellation,
    ) -> Result<GitOutput, Error> {
        let mut all = vec!["-c".into(), "advice.graftFileDeprecated=false".into()];
        all.extend(args);
        self.command_env(
            repo,
            all,
            cancel,
            &[("GIT_GRAFT_FILE".into(), "/dev/null".into())],
        )
    }
}
impl Repository {
    fn pull_history_ready(&self, b: &mut Budget, c: &Cancellation) -> Result<(), Error> {
        if b.command(self, args(&["rev-parse", "--is-shallow-repository"]), c)?
            .stdout
            != b"false\n"
        {
            return Err(Error::InvalidInput(
                "pull preview requires complete non-shallow history",
            ));
        }
        let grafts = output_path(
            &b.command(
                self,
                args(&[
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-path",
                    "info/grafts",
                ]),
                c,
            )?
            .stdout,
        )?;
        match fs::symlink_metadata(grafts) {
            Ok(_) => {
                return Err(Error::InvalidInput(
                    "remove legacy grafts before pull preview",
                ))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::Io(e.to_string())),
        }
        Ok(())
    }
    fn pull_address(
        &self,
        remote: &[u8],
        b: &mut Budget,
        c: &Cancellation,
    ) -> Result<Vec<u8>, Error> {
        if !self
            .remotes(b.policy()?, c)?
            .value
            .iter()
            .any(|v| v == remote)
        {
            return Err(Error::InvalidInput("choose a configured remote"));
        }
        let mut a = args(&["remote", "get-url", "--all", "--"]);
        a.push(OsString::from_vec(remote.to_vec()));
        let address = line(&b.pull_command(self, a, c)?.stdout)?;
        if address.starts_with(b"-") || address.windows(2).any(|v| v == b"::") {
            return Err(Error::InvalidInput("unsupported fetch address"));
        }
        Ok(address)
    }
    fn pull_oid(&self, b: &mut Budget, c: &Cancellation) -> Result<Vec<u8>, Error> {
        let oid = line(
            &b.pull_command(
                self,
                args(&["rev-parse", "--verify", "FETCH_HEAD^{commit}"]),
                c,
            )?
            .stdout,
        )?;
        check_oid(&oid)?;
        Ok(oid)
    }
    fn pull_state(&self, b: &mut Budget, c: &Cancellation) -> Result<PullState, Error> {
        let files = self.switch_state_with(b, c)?;
        let mut operations = Vec::new();
        for marker in [
            "MERGE_HEAD",
            "rebase-merge",
            "rebase-apply",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "BISECT_LOG",
            "sequencer",
        ] {
            let p = output_path(
                &b.pull_command(
                    self,
                    args(&["rev-parse", "--path-format=absolute", "--git-path", marker]),
                    c,
                )?
                .stdout,
            )?;
            match fs::symlink_metadata(p) {
                Ok(_) => operations.push(marker.to_owned()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(Error::Io(e.to_string())),
            }
        }
        let fetched_oid = match self.pull_oid(b, c) {
            Ok(v) => Some(v),
            Err(Error::GitFailed(_)) => None,
            Err(e) => return Err(e),
        };
        Ok(PullState {
            files,
            operations,
            fetched_oid,
        })
    }
    fn pull_ready(
        &self,
        s: &PullState,
        strategy: PullStrategy,
        b: &mut Budget,
        c: &Cancellation,
    ) -> Result<(), Error> {
        if s.files.status.value.detached
            || s.files.status.value.branch.is_none()
            || s.files.status.value.head_oid.is_none()
        {
            return Err(Error::InvalidInput(
                "pull requires an existing local branch",
            ));
        }
        if !s.operations.is_empty() {
            return Err(Error::InvalidInput("another Git operation is in progress"));
        }
        if s.files
            .status
            .value
            .changes
            .iter()
            .any(|v| matches!(v.kind, ChangeKind::Unmerged))
        {
            return Err(Error::InvalidInput(
                "resolve existing conflicts before pull",
            ));
        }
        self.switch_source(&s.files, b, c)?;
        if strategy != PullStrategy::FastForwardOnly {
            for key in ["user.name", "user.email"] {
                let value = b.pull_command(self, args(&["config", "--get", key]), c)?;
                if value.stdout.iter().all(u8::is_ascii_whitespace) {
                    return Err(Error::InvalidInput(
                        "configure user.name and user.email before merge or rebase",
                    ));
                }
            }
        }
        Ok(())
    }
    fn pull_config(&self, budget: &mut Budget, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
        self.switch_config(budget, cancel).map_err(redact_error)
    }
    /// Explizit angeforderter Fetch schreibt Refs/FETCH_HEAD, integriert aber keine Dateien.
    pub fn prepare_pull(
        &self,
        remote: Vec<u8>,
        branch: Vec<u8>,
        strategy: PullStrategy,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<PullPreview, Error> {
        self.prepare_pull_inner(remote, branch, strategy, policy, cancel, observer)
            .map_err(redact_error)
    }
    fn prepare_pull_inner(
        &self,
        remote: Vec<u8>,
        branch: Vec<u8>,
        strategy: PullStrategy,
        policy: Policy,
        c: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> Result<PullPreview, Error> {
        let _lease = self.try_operation()?;
        let mut b = Budget::new(policy);
        self.verify(b.policy()?, c)?;
        let identity = self.operation_identity()?;
        if branch.is_empty() || branch.starts_with(b"-") || branch.contains(&0) {
            return Err(Error::InvalidInput("invalid source branch"));
        }
        let mut full = b"refs/heads/".to_vec();
        full.extend(&branch);
        let mut a = args(&["check-ref-format"]);
        a.push(OsString::from_vec(full.clone()));
        b.pull_command(self, a, c)?;
        self.pull_history_ready(&mut b, c)?;
        let address = self.pull_address(&remote, &mut b, c)?;
        let before = self.pull_state(&mut b, c)?;
        self.pull_ready(&before, strategy, &mut b, c)?;
        let config = self.pull_config(&mut b, c)?;
        let hook_dir = output_path(
            &b.pull_command(
                self,
                args(&["rev-parse", "--path-format=absolute", "--git-path", "hooks"]),
                c,
            )?
            .stdout,
        )?;
        let hooks = self.commit_hooks(&hook_dir, c)?.0;
        let mut a = args(&[
            "fetch",
            "--no-tags",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "--no-prune",
            "--progress",
            "--",
        ]);
        a.extend([OsString::from_vec(remote.clone()), OsString::from_vec(full)]);
        call(self, a, &mut b, c, observer)?;
        let source = self.pull_state(&mut b, c)?;
        if source.files.staged != before.files.staged
            || source.files.working != before.files.working
            || source.files.status.value.head_oid != before.files.status.value.head_oid
            || source.files.status.value.branch != before.files.status.value.branch
            || source.files.status.value.changes != before.files.status.value.changes
            || source.operations != before.operations
            || self.pull_config(&mut b, c)? != config
            || self.commit_hooks(&hook_dir, c)?.0 != hooks
        {
            return Err(Error::StalePreview);
        }
        self.pull_ready(&source, strategy, &mut b, c)?;
        let target = source
            .fetched_oid
            .as_ref()
            .ok_or(Error::MalformedOutput("missing fetched commit"))?;
        let head = source.files.status.value.head_oid.as_ref().unwrap();
        let patch = args(&[
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--binary",
            "--full-index",
            "--no-renames",
            "--ignore-submodules=none",
            "--submodule=short",
        ]);
        let mut a = args(&["diff"]);
        a.extend(patch.clone());
        a.extend([
            OsString::from_vec(head.clone()),
            OsString::from_vec(target.clone()),
            "--".into(),
        ]);
        let delta = b.pull_command(self, a, c)?;
        let commits = |left: &[u8], right: &[u8], b: &mut Budget| -> Result<GitOutput, Error> {
            let mut a = args(&[
                "log",
                "--format=fuller",
                "--no-show-signature",
                "--reverse",
                "--topo-order",
                "--root",
                "--patch",
                "--diff-merges=separate",
            ]);
            a.extend(patch.clone());
            a.push(OsString::from_vec([left, b"..", right].concat()));
            a.push("--".into());
            b.pull_command(self, a, c)
        };
        let incoming = commits(head, target, &mut b)?;
        let local = commits(target, head, &mut b)?;
        let mut paths = Vec::new();
        let mut unique_paths = std::collections::HashSet::<Vec<u8>>::new();
        let mut path_bytes = 0usize;
        for tree in [None, Some(head), Some(target)] {
            let a = match tree {
                None => args(&[
                    "ls-files",
                    "-z",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                ]),
                Some(oid) => {
                    let mut a = args(&["ls-tree", "-r", "--name-only", "-z"]);
                    a.push(OsString::from_vec(oid.clone()));
                    a
                }
            };
            for p in b
                .pull_command(self, a, c)?
                .stdout
                .split(|v| *v == 0)
                .filter(|p| !p.is_empty())
            {
                if c.is_cancelled() {
                    return Err(Error::Cancelled(GitOutput::empty()));
                }
                if unique_paths.contains(p) {
                    continue;
                }
                if paths.len() >= mutation::MAX_PULL_PATHS {
                    return Err(Error::InvalidInput("pull preview limit: 65536 paths"));
                }
                if p.len() > (1024 * 1024usize).saturating_sub(path_bytes) {
                    return Err(Error::InvalidInput("pull preview limit: 1 MiB path bytes"));
                }
                let path = RepoPath::new(p.to_vec())?;
                path_bytes += p.len();
                unique_paths.insert(p.to_vec());
                paths.push(path);
            }
        }
        let mut ignored = args(&[
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "-z",
            "--",
        ]);
        ignored.extend(paths.iter().map(RepoPath::argument));
        if !b.pull_command(self, ignored, c)?.stdout.is_empty() {
            return Err(Error::InvalidInput(
                "pull source collides with ignored local files; move them before preview",
            ));
        }
        let bindings = mutation::SwitchBindings::capture_pull(self, paths, c)?;
        let refs = b
            .pull_command(self, args(&["show-ref", "--head"]), c)?
            .stdout;
        if self.pull_state(&mut b, c)? != source
            || self.pull_config(&mut b, c)? != config
            || self.pull_address(&remote, &mut b, c)? != address
            || self.commit_hooks(&hook_dir, c)?.0 != hooks
            || self.operation_identity()? != identity
        {
            return Err(Error::StalePreview);
        }
        bindings.verify(self, c)?;
        Ok(PullPreview {
            repository: self.clone(),
            identity,
            remote,
            branch,
            address,
            strategy,
            source,
            config,
            refs,
            hooks,
            hook_dir,
            bindings,
            incoming,
            local,
            delta,
        })
    }
}
impl PullPreview {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn remote(&self) -> &[u8] {
        &self.remote
    }
    pub fn branch(&self) -> &[u8] {
        &self.branch
    }
    pub fn strategy(&self) -> PullStrategy {
        self.strategy
    }
    pub fn source(&self) -> &PullState {
        &self.source
    }
    pub fn incoming(&self) -> &GitOutput {
        &self.incoming
    }
    pub fn local(&self) -> &GitOutput {
        &self.local
    }
    pub fn delta(&self) -> &GitOutput {
        &self.delta
    }
    pub fn address_display(&self) -> String {
        address_display(&self.address)
    }
    fn verify(&self, b: &mut Budget, c: &Cancellation) -> Result<(), Error> {
        let r = &self.repository;
        r.verify(b.policy()?, c)?;
        r.pull_history_ready(b, c)?;
        if r.operation_identity()? != self.identity {
            return Err(Error::StaleRepository);
        }
        if r.pull_state(b, c)? != self.source
            || r.pull_config(b, c)? != self.config
            || r.pull_address(&self.remote, b, c)? != self.address
            || b.pull_command(r, args(&["show-ref", "--head"]), c)?.stdout != self.refs
            || r.commit_hooks(&self.hook_dir, c)?.0 != self.hooks
        {
            return Err(Error::StalePreview);
        }
        self.bindings.verify(r, c)?;
        r.verify(b.policy()?, c)?;
        if r.operation_identity()? != self.identity {
            return Err(Error::StaleRepository);
        }
        Ok(())
    }
    pub fn execute(
        self,
        policy: Policy,
        c: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> PullReport {
        let r = &self.repository;
        let mut b = Budget::new(policy);
        let lease = r.try_operation();
        let mut started = false;
        let result = match &lease {
            Err(e) => Err(e.clone()),
            Ok(_) => (|| {
                self.verify(&mut b, c)?;
                r.pull_ready(&self.source, self.strategy, &mut b, c)?;
                self.verify(&mut b, c)?;
                let mut a = args(&[
                    "pull",
                    "--no-autostash",
                    "--no-recurse-submodules",
                    "--no-edit",
                    "--progress",
                ]);
                a.extend(match self.strategy {
                    PullStrategy::FastForwardOnly => args(&["--ff-only"]),
                    PullStrategy::Merge => args(&["--no-rebase", "--ff"]),
                    PullStrategy::Rebase => args(&["--rebase"]),
                });
                a.push("--".into());
                a.push(OsString::from_vec(self.remote.clone()));
                a.push(OsString::from_vec(
                    [b"refs/heads/".as_slice(), &self.branch].concat(),
                ));
                started = true;
                call(r, a, &mut b, c, observer)
            })(),
        };
        // Nach gestarteter Git-Mutation gilt ein eigener Scan trotz Abbruch/Timeout.
        let scan = Cancellation::default();
        let mut b = Budget::new(policy);
        let state = (|| {
            r.verify(b.policy()?, &scan)?;
            if r.operation_identity()? != self.identity {
                return Err(Error::StaleRepository);
            }
            r.pull_state(&mut b, &scan)
        })();
        let integration = (|| {
            let state = state.as_ref().map_err(Clone::clone)?;
            if !state.operations.is_empty()
                || state.files.status.value.branch != self.source.files.status.value.branch
            {
                return Ok(false);
            }
            let oid = state
                .fetched_oid
                .as_ref()
                .ok_or(Error::MalformedOutput("post-pull FETCH_HEAD is missing"))?;
            let mut a = args(&["merge-base", "--is-ancestor"]);
            a.push(OsString::from_vec(oid.clone()));
            a.push("HEAD".into());
            match b.pull_command(r, a, &scan) {
                Ok(_) => Ok(true),
                Err(Error::GitFailed(out)) if out.exit_code == Some(1) => Ok(false),
                Err(e) => Err(e),
            }
        })();
        let delta = (|| {
            let actual = state
                .as_ref()
                .map_err(Clone::clone)?
                .files
                .status
                .value
                .head_oid
                .as_ref()
                .ok_or(Error::MalformedOutput("post-pull HEAD is missing"))?;
            let original = self.source.files.status.value.head_oid.as_ref().unwrap();
            let mut a = args(&[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                "--binary",
                "--full-index",
                "--no-renames",
                "--ignore-submodules=none",
                "--submodule=short",
            ]);
            a.extend([
                OsString::from_vec(original.clone()),
                OsString::from_vec(actual.clone()),
                "--".into(),
            ]);
            b.pull_command(r, a, &scan)
        })();
        drop(lease);
        PullReport {
            result: result.map_err(redact_error),
            state: state.map_err(redact_error),
            integration: integration.map_err(redact_error),
            delta: delta.map_err(redact_error),
            started,
        }
    }
}
#[derive(Debug)]
pub struct PullReport {
    pub result: Result<GitOutput, Error>,
    pub state: Result<PullState, Error>,
    pub integration: Result<bool, Error>,
    pub delta: Result<GitOutput, Error>,
    pub started: bool,
}
impl PullReport {
    pub fn integrated(&self) -> bool {
        self.integration.as_ref().is_ok_and(|value| *value) && self.delta.is_ok()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn incomplete_url_at_capture_boundary_never_exports_partial_credentials() {
        for value in [
            b"https://synthetic-token".as_slice(),
            b"https://fixture:synthetic-password",
        ] {
            let clean = redact_bytes(value);
            assert_eq!(clean, b"https://[redacted]");
        }
    }
    #[test]
    fn redirected_and_normalized_urls_hide_credentials_without_losing_other_bytes() {
        let value=b"fatal https://fixture:synthetic-password@example.invalid/changed?token=synthetic-token\nraw \xff\n";
        let clean = redact_bytes(value);
        assert!(!clean.windows(18).any(|v| v == b"synthetic-password"));
        assert!(!clean.windows(15).any(|v| v == b"synthetic-token"));
        assert!(clean.ends_with(b"raw \xff\n"));
        assert!(String::from_utf8_lossy(&clean).contains("https://example.invalid/changed"));
    }
}
