//! Lokale Branches an einer bestätigten Commit-ID erstellen; kein Checkout.
use crate::*;
use std::os::unix::fs::PermissionsExt;

#[derive(Debug, Clone)]
pub struct LocalBranches {
    pub branches: Vec<Branch>,
    pub head_oid: Option<Vec<u8>>,
    pub current_branch: Option<Vec<u8>>,
}
#[derive(Debug)]
pub struct BranchCreationPreview {
    repository: Repository,
    identity: (u64, u64),
    name: Vec<u8>,
    commit: Vec<u8>,
    subject: Vec<u8>,
    output: GitOutput,
}
impl BranchCreationPreview {
    pub fn root(&self) -> &Path {
        self.repository.root()
    }
    pub fn name(&self) -> &[u8] {
        &self.name
    }
    pub fn commit(&self) -> &[u8] {
        &self.commit
    }
    pub fn subject(&self) -> &[u8] {
        &self.subject
    }
    pub fn output(&self) -> &GitOutput {
        &self.output
    }
}
impl Repository {
    pub fn local_branches(
        &self,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<ReadResult<LocalBranches>, Error> {
        let branches = self.branches(policy, cancellation)?;
        let status = self.status(policy, cancellation)?;
        let mut output = branches.output;
        output.stderr.extend_from_slice(&status.output.stderr);
        let branches: Vec<_> = branches
            .value
            .into_iter()
            .filter(|b| b.full_name.starts_with(b"refs/heads/"))
            .collect();
        if branches.len() > 2000 {
            return Err(Error::InvalidInput("local branch list limit: 2000"));
        }
        Ok(ReadResult {
            value: LocalBranches {
                branches,
                head_oid: status.value.head_oid,
                current_branch: status.value.branch,
            },
            output,
        })
    }
    fn branch_commit(
        &self,
        oid: &[u8],
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<(Vec<u8>, Vec<u8>, GitOutput), Error> {
        if !matches!(oid.len(), 40 | 64) || !oid.iter().all(u8::is_ascii_hexdigit) {
            return Err(Error::InvalidInput(
                "use a complete 40- or 64-digit commit ID",
            ));
        }
        self.verify(policy, cancellation)?;
        let output = self.git.checked_env(
            &self.root,
            &[
                "show".into(),
                "--no-patch".into(),
                "--no-notes".into(),
                "--no-show-signature".into(),
                "--format=%H%x00%s%x00".into(),
                OsString::from_vec(oid.to_vec()),
                "--".into(),
            ],
            policy,
            cancellation,
            &[("GIT_NO_REPLACE_OBJECTS".into(), "1".into())],
        )?;
        let fields: Vec<_> = output.stdout.split(|b| *b == 0).collect();
        if fields.len() != 3 || fields[2] != b"\n" || fields[0] != oid.to_ascii_lowercase() {
            return Err(Error::InvalidInput(
                "target must identify one commit object directly",
            ));
        }
        Ok((fields[0].to_vec(), fields[1].to_vec(), output))
    }
    fn branch_hook_check(&self, policy: Policy, cancellation: &Cancellation) -> Result<(), Error> {
        let output = self.read(
            &[
                "rev-parse".into(),
                "--path-format=absolute".into(),
                "--git-path".into(),
                "hooks/reference-transaction".into(),
            ],
            policy,
            cancellation,
        )?;
        let path = output_path(&output.stdout)?;
        match fs::metadata(path) {
            Ok(metadata) if metadata.permissions().mode() & 0o111 != 0 => Err(Error::InvalidInput(
                "reference-transaction hook requires the Git CLI",
            )),
            Ok(_) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(Error::Io(error.to_string())),
        }
    }
    pub fn prepare_branch_creation(
        &self,
        name: Vec<u8>,
        oid: Vec<u8>,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<BranchCreationPreview, Error> {
        if name.is_empty() || name.len() > 1024 || name.contains(&0) {
            return Err(Error::InvalidInput("invalid local branch name"));
        }
        self.verify(policy, cancellation)?;
        let identity = self.operation_identity()?;
        let name_output = self.git.checked(
            &self.root,
            &[
                "check-ref-format".into(),
                "--branch".into(),
                OsString::from_vec(name.clone()),
            ],
            policy,
            cancellation,
        )?;
        if name_output.stdout.strip_suffix(b"\n") != Some(name.as_slice()) {
            return Err(Error::InvalidInput(
                "branch aliases are not accepted as literal names",
            ));
        }
        self.branch_hook_check(policy, cancellation)?;
        let (commit, subject, mut output) = self.branch_commit(&oid, policy, cancellation)?;
        output.stderr.extend_from_slice(&name_output.stderr);
        if self.operation_identity()? != identity {
            return Err(Error::StaleRepository);
        }
        Ok(BranchCreationPreview {
            repository: self.clone(),
            identity,
            name,
            commit,
            subject,
            output,
        })
    }
    /// Die vollständige OID bleibt das Ziel; ein geänderter HEAD wird weder gelesen noch geschrieben.
    pub fn create_branch(
        &self,
        preview: BranchCreationPreview,
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<GitOutput, Error> {
        let _operation = self.try_operation()?;
        if self.root != preview.repository.root
            || self.git_dir != preview.repository.git_dir
            || self.root_identity != preview.repository.root_identity
            || self.git_identity != preview.repository.git_identity
            || self.operation_identity()? != preview.identity
        {
            return Err(Error::StaleRepository);
        }
        self.verify(policy, cancellation)?;
        self.branch_hook_check(policy, cancellation)?;
        let (commit, subject, _) = self.branch_commit(&preview.commit, policy, cancellation)?;
        if commit != preview.commit || subject != preview.subject {
            return Err(Error::StalePreview);
        }
        self.verify(policy, cancellation)?;
        if self.operation_identity()? != preview.identity {
            return Err(Error::StaleRepository);
        }
        self.git.checked_env(
            &self.root,
            &[
                "branch".into(),
                "--no-track".into(),
                "--".into(),
                OsString::from_vec(preview.name),
                OsString::from_vec(preview.commit),
            ],
            policy,
            cancellation,
            &[("GIT_NO_REPLACE_OBJECTS".into(), "1".into())],
        )
    }
}
#[cfg(test)]
mod tests;
