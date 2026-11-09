//! Normaler lokaler Branchwechsel mit verbrauchter Vorschau; keine externe Git-Atomizität.
use crate::*;
use std::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwitchState {
    pub status: ReadResult<Status>,
    pub staged: GitOutput,
    pub working: GitOutput,
}
pub struct SwitchPreview {
    repository: Repository,
    identity: (u64, u64),
    target: Vec<u8>,
    target_oid: Vec<u8>,
    source: SwitchState,
    delta: GitOutput,
    config: Vec<u8>,
    bindings: mutation::SwitchBindings,
}
impl std::fmt::Debug for SwitchPreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SwitchPreview")
            .field("target", &self.target)
            .field("target_oid", &self.target_oid)
            .finish_non_exhaustive()
    }
}
impl SwitchPreview {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn target(&self) -> &[u8] {
        &self.target
    }
    pub fn target_oid(&self) -> &[u8] {
        &self.target_oid
    }
    pub fn source(&self) -> &SwitchState {
        &self.source
    }
    pub fn delta(&self) -> &GitOutput {
        &self.delta
    }
    /// Selbst bei Fehler oder Abbruch können Git oder seine Hooks bereits geschrieben haben.
    pub fn execute(
        self,
        policy: Policy,
        cancel: &Cancellation,
        observer: &mut dyn FnMut(&[u8]),
    ) -> SwitchReport {
        let repo = &self.repository;
        let mut budget = Budget::new(policy);
        let lease = repo.try_operation();
        let result = match &lease {
            Err(e) => Err(e.clone()),
            Ok(_) => (|| {
                repo.verify(budget.policy()?, cancel)?;
                if repo.operation_identity()? != self.identity {
                    return Err(Error::StaleRepository);
                }
                if repo.switch_state_with(&mut budget, cancel)? != self.source
                    || repo.switch_target(&self.target, &mut budget, cancel)? != self.target_oid
                    || repo.switch_config(&mut budget, cancel)? != self.config
                {
                    return Err(Error::StalePreview);
                }
                self.bindings.verify(repo, cancel)?;
                repo.switch_source(&self.source, &mut budget, cancel)?;
                if repo.switch_state_with(&mut budget, cancel)?.status.value
                    != self.source.status.value
                    || repo.switch_target(&self.target, &mut budget, cancel)? != self.target_oid
                {
                    return Err(Error::StalePreview);
                }
                repo.verify(budget.policy()?, cancel)?;
                if repo.operation_identity()? != self.identity {
                    return Err(Error::StaleRepository);
                }
                let mut args: Vec<OsString> = [
                    "--no-pager",
                    "-c",
                    "color.ui=false",
                    "-c",
                    "core.fsmonitor=false",
                    "switch",
                    "--no-guess",
                    "--no-overwrite-ignore",
                    "--no-recurse-submodules",
                    "--progress",
                    "--",
                ]
                .into_iter()
                .map(Into::into)
                .collect();
                args.push(OsString::from_vec(
                    self.target.strip_prefix(b"refs/heads/").unwrap().to_vec(),
                ));
                let environment = fastra_process::Environment {
                    remove_prefixes: vec!["GIT_".into()],
                    set: [
                        ("GIT_TERMINAL_PROMPT", "0"),
                        ("GIT_NO_LAZY_FETCH", "1"),
                        ("GIT_ALLOW_PROTOCOL", ""),
                        ("GIT_ASKPASS", "/usr/bin/false"),
                        ("SSH_ASKPASS", "/usr/bin/false"),
                        ("SSH_ASKPASS_REQUIRE", "never"),
                        ("GIT_EDITOR", "/usr/bin/false"),
                        ("GIT_NO_REPLACE_OBJECTS", "1"),
                    ]
                    .into_iter()
                    .map(|(k, v)| (k.into(), v.into()))
                    .collect(),
                };
                let out = fastra_process::run_with_stderr(
                    &repo.git.executable,
                    &repo.root,
                    &args,
                    budget.policy()?,
                    cancel,
                    &environment,
                    fastra_process::ParentLoss::Terminate,
                    observer,
                )
                .map_err(Error::from)?;
                if out.success() {
                    Ok(out)
                } else {
                    Err(Error::GitFailed(out))
                }
            })(),
        };
        // Eigene, endliche Nachprüfung auch nach Cancel; die Lease bleibt bis danach gehalten.
        let state = (|| {
            let scan_cancel = Cancellation::default();
            let mut scan_budget = Budget::new(policy);
            repo.verify(scan_budget.policy()?, &scan_cancel)?;
            if repo.operation_identity()? != self.identity {
                return Err(Error::StaleRepository);
            }
            repo.switch_state_with(&mut scan_budget, &scan_cancel)
        })();
        drop(lease);
        SwitchReport {
            result,
            state,
            expected_target: self.target,
            expected_oid: self.target_oid,
        }
    }
}
#[derive(Debug)]
pub struct SwitchReport {
    pub result: Result<GitOutput, Error>,
    pub state: Result<SwitchState, Error>,
    pub expected_target: Vec<u8>,
    pub expected_oid: Vec<u8>,
}
impl SwitchReport {
    pub fn target_reached(&self) -> bool {
        self.state.as_ref().is_ok_and(|s| {
            s.status.value.head_oid.as_deref() == Some(self.expected_oid.as_slice())
                && s.status.value.branch.as_ref().is_some_and(|b| {
                    self.expected_target.strip_prefix(b"refs/heads/") == Some(b.as_slice())
                })
        })
    }
}
pub(super) struct Budget {
    policy: Policy,
    started: Instant,
    stdout: usize,
    stderr: usize,
}
impl Budget {
    pub(super) fn new(policy: Policy) -> Self {
        Self {
            policy,
            started: Instant::now(),
            stdout: policy.stdout_bytes,
            stderr: policy.stderr_bytes,
        }
    }
    pub(super) fn policy(&self) -> Result<Policy, Error> {
        let timeout = self.policy.timeout.saturating_sub(self.started.elapsed());
        if timeout.is_zero() {
            return Err(Error::TimedOut(GitOutput::empty()));
        }
        if self.stdout == 0 || self.stderr == 0 {
            return Err(Error::OutputLimit(GitOutput::empty()));
        }
        Ok(Policy {
            timeout,
            stdout_bytes: self.stdout,
            stderr_bytes: self.stderr,
            ..self.policy
        })
    }
    pub(super) fn consume(&mut self, out: &GitOutput) { self.stdout=self.stdout.saturating_sub(out.stdout.len()); self.stderr=self.stderr.saturating_sub(out.stderr.len()); }
    pub(super) fn command(&mut self,repo:&Repository,args:Vec<OsString>,cancel:&Cancellation)->Result<GitOutput,Error>{self.command_env(repo,args,cancel,&[])}
    pub(super) fn command_env(&mut self,repo:&Repository,args:Vec<OsString>,cancel:&Cancellation,extra:&[(OsString,OsString)])->Result<GitOutput,Error>{
        let mut environment=vec![("GIT_NO_REPLACE_OBJECTS".into(),"1".into())];environment.extend_from_slice(extra);
        let out = repo.git.checked_env(
            &repo.root,
            &args,
            self.policy()?,
            cancel,
            &environment,
        )?;
        self.stdout = self.stdout.saturating_sub(out.stdout.len());
        self.stderr = self.stderr.saturating_sub(out.stderr.len());
        Ok(out)
    }
}
fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(Into::into).collect()
}
impl Repository {
    pub(super) fn switch_config(&self, budget: &mut Budget, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
        Ok(budget
            .command(
                self,
                args(&[
                    "config",
                    "--null",
                    "--list",
                    "--show-origin",
                    "--show-scope",
                ]),
                cancel,
            ).map_err(crate::clear_config_stdout)?
            .stdout)
    }
    pub(super) fn switch_target(
        &self,
        target: &[u8],
        budget: &mut Budget,
        cancel: &Cancellation,
    ) -> Result<Vec<u8>, Error> {
        let Some(short) = target.strip_prefix(b"refs/heads/") else {
            return Err(Error::InvalidInput("choose an existing local branch"));
        };
        if short.is_empty() || short.starts_with(b"-") || target.contains(&0) {
            return Err(Error::InvalidInput("invalid local target branch"));
        }
        let mut literal = args(&["check-ref-format", "--branch"]);
        literal.push(OsString::from_vec(short.to_vec()));
        if budget
            .command(self, literal, cancel)?
            .stdout
            .strip_suffix(b"\n")
            != Some(short)
        {
            return Err(Error::InvalidInput(
                "branch aliases are not accepted as literal targets",
            ));
        }
        let mut a = args(&["show-ref", "--verify", "--hash", "--"]);
        a.push(OsString::from_vec(target.to_vec()));
        let out = budget.command(self, a, cancel)?;
        let oid = out
            .stdout
            .strip_suffix(b"\n")
            .ok_or(Error::MalformedOutput("branch object ID"))?;
        check_oid(oid)?;
        let mut a = args(&["cat-file", "-t"]);
        a.push(OsString::from_vec(oid.to_vec()));
        if budget.command(self, a, cancel)?.stdout != b"commit\n" {
            return Err(Error::InvalidInput("target must be a commit"));
        }
        Ok(oid.to_vec())
    }
    pub(super) fn switch_source(
        &self,
        state: &SwitchState,
        budget: &mut Budget,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        let oid = state
            .status
            .value
            .head_oid
            .as_ref()
            .ok_or(Error::InvalidInput(
                "branch switching requires an existing HEAD commit",
            ))?;
        if let Some(name) = &state.status.value.branch {
            let mut full = b"refs/heads/".to_vec();
            full.extend_from_slice(name);
            if self.switch_target(&full, budget, cancel)? != *oid {
                return Err(Error::StalePreview);
            }
        } else if !state.status.value.detached {
            return Err(Error::StalePreview);
        }
        Ok(())
    }
    pub(super) fn switch_state_with(
        &self,
        budget: &mut Budget,
        cancel: &Cancellation,
    ) -> Result<SwitchState, Error> {
        self.verify(budget.policy()?, cancel)?;
        let output = budget.command(
            self,
            args(&[
                "status",
                "--porcelain=v2",
                "--branch",
                "--untracked-files=all",
                "-z",
            ]),
            cancel,
        )?;
        let status = ReadResult {
            value: parse_status(&output.stdout)?,
            output,
        };
        let base = [
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--binary",
            "--full-index",
            "--no-renames",
            "--ignore-submodules=none",
            "--submodule=short",
        ];
        let mut a = args(&base);
        a.extend(args(&["--cached", "--"]));
        let staged = budget.command(self, a, cancel)?;
        let mut a = args(&base);
        a.push("--".into());
        let working = budget.command(self, a, cancel)?;
        Ok(SwitchState {
            status,
            staged,
            working,
        })
    }
    pub fn switch_state(
        &self,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<SwitchState, Error> {
        self.switch_state_with(&mut Budget::new(policy), cancel)
    }
    pub fn prepare_switch(
        &self,
        target: Vec<u8>,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<SwitchPreview, Error> {
        let mut budget = Budget::new(policy);
        self.verify(budget.policy()?, cancel)?;
        let identity = self.operation_identity()?;
        let source = self.switch_state_with(&mut budget, cancel)?;
        let Some(source_oid) = source.status.value.head_oid.as_ref() else {
            return Err(Error::InvalidInput(
                "branch switching requires an existing HEAD commit",
            ));
        };
        self.switch_source(&source, &mut budget, cancel)?;
        let target_oid = self.switch_target(&target, &mut budget, cancel)?;
        if source
            .status
            .value
            .branch
            .as_ref()
            .is_some_and(|s| target.strip_prefix(b"refs/heads/") == Some(s.as_slice()))
        {
            return Err(Error::InvalidInput("choose a different local branch"));
        }
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
            OsString::from_vec(source_oid.clone()),
            OsString::from_vec(target_oid.clone()),
            "--".into(),
        ]);
        let delta = budget.command(self, a, cancel)?;
        let mut a = args(&[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--name-only",
            "-z",
        ]);
        a.extend([
            OsString::from_vec(source_oid.clone()),
            OsString::from_vec(target_oid.clone()),
            "--".into(),
        ]);
        let names = budget.command(self, a, cancel)?;
        let mut paths = Vec::new();
        for name in names.stdout.split(|b| *b == 0).filter(|n| !n.is_empty()) {
            paths.push(RepoPath::new(name.to_vec())?);
        }
        for change in &source.status.value.changes {
            if !paths.contains(&change.path) {
                paths.push(change.path.clone());
            }
            if let ChangeKind::RenameOrCopy { original, .. } = &change.kind {
                if !paths.contains(original) {
                    paths.push(original.clone());
                }
            }
        }
        let bindings = mutation::SwitchBindings::capture(self, paths, cancel)?;
        let config = self.switch_config(&mut budget, cancel)?;
        if self.switch_state_with(&mut budget, cancel)? != source
            || self.switch_target(&target, &mut budget, cancel)? != target_oid
            || self.operation_identity()? != identity
        {
            return Err(Error::StalePreview);
        }
        bindings.verify(self, cancel)?;
        Ok(SwitchPreview {
            repository: self.clone(),
            identity,
            target,
            target_oid,
            source,
            delta,
            config,
            bindings,
        })
    }
}
