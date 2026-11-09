//! Unveränderliche historische Git-Objekte; keine Arbeitsbaum-/Indexänderung.
use crate::*;
const MAX_BLOB: usize = 1024 * 1024;
#[derive(Clone, Debug)]
pub struct Commit {
    pub oid: String,
    pub parents: Vec<String>,
    pub author: String,
    pub date: String,
    pub subject: String,
}
#[derive(Clone, Debug)]
pub struct History {
    repository: Repository,
    pub commits: Vec<Commit>,
    pub graph: GitOutput,
    pub metadata_output: GitOutput,
}
#[derive(Clone, Debug)]
pub struct HistoricalChange {
    pub old_path: RepoPath,
    pub new_path: RepoPath,
    pub old_mode: String,
    pub new_mode: String,
    pub status: String,
    old_oid: Option<String>,
    new_oid: Option<String>,
}
#[derive(Clone, Debug)]
pub struct HistoricalBlob {
    pub oid: Option<String>,
    pub mode: String,
    pub bytes: Vec<u8>,
}
impl HistoricalBlob {
    pub fn text(&self) -> Option<&str> {
        if !matches!(self.mode.as_str(), "100644" | "100755" | "000000") || self.bytes.contains(&0)
        {
            None
        } else {
            std::str::from_utf8(&self.bytes).ok()
        }
    }
}
#[derive(Clone, Debug)]
pub struct HistoricalPair {
    pub before: HistoricalBlob,
    pub after: HistoricalBlob,
    pub warnings: Vec<Vec<u8>>,
}
#[derive(Clone, Debug)]
pub struct CommitChanges {
    repository: Repository,
    pub commit: Commit,
    pub parent: Option<String>,
    changes: Vec<HistoricalChange>,
    pub output: GitOutput,
    pub metadata_output: GitOutput,
}
fn oid(value: &[u8]) -> Result<String, Error> {
    check_oid(value)?;
    String::from_utf8(value.to_vec()).map_err(|_| Error::MalformedOutput("OID"))
}
fn commits(bytes: &[u8]) -> Result<Vec<Commit>, Error> {
    let mut fields: Vec<_> = bytes.split(|b| *b == 0).collect();
    if fields.last() == Some(&&b""[..]) {
        fields.pop();
    }
    if fields.len() % 5 != 0 {
        return Err(Error::MalformedOutput("history fields"));
    }
    fields
        .chunks_exact(5)
        .map(|f| {
            Ok(Commit {
                oid: oid(f[0])?,
                parents: if f[1].is_empty() {
                    Vec::new()
                } else {
                    f[1].split(|b| *b == b' ')
                        .map(oid)
                        .collect::<Result<_, _>>()?
                },
                author: String::from_utf8(f[2].to_vec())
                    .map_err(|_| Error::MalformedOutput("UTF-8 author"))?,
                date: String::from_utf8(f[3].to_vec())
                    .map_err(|_| Error::MalformedOutput("UTF-8 date"))?,
                subject: String::from_utf8(f[4].to_vec())
                    .map_err(|_| Error::MalformedOutput("UTF-8 subject"))?,
            })
        })
        .collect()
}
fn log_args() -> Vec<OsString> {
    [
        "--no-show-signature",
        "--format=%H%x00%P%x00%an%x00%aI%x00%s",
        "-z",
    ]
    .into_iter()
    .map(Into::into)
    .collect()
}
impl Repository {
    fn historical_read(
        &self,
        args: &[OsString],
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<GitOutput, Error> {
        let mut fixed = vec![OsString::from("--no-replace-objects")];
        fixed.extend_from_slice(args);
        self.read(&fixed, policy, cancel)
    }
    pub fn history(
        &self,
        count: u32,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<History, Error> {
        if count == 0 || count > 200 {
            return Err(Error::InvalidInput("history limit: 200 commits"));
        }
        let mut args = vec!["log".into()];
        args.extend(log_args());
        args.extend([format!("-{count}").into(), "--all".into(), "--".into()]);
        let metadata_output = self.historical_read(&args, policy, cancel)?;
        let commits = commits(&metadata_output.stdout)?;
        let mut graph_args: Vec<OsString> = [
            "log",
            "--graph",
            "--oneline",
            "--decorate",
            "--no-color",
            "--no-show-signature",
        ]
        .into_iter()
        .map(Into::into)
        .collect();
        graph_args.push(format!("-{count}").into());
        graph_args.extend(commits.iter().map(|c| OsString::from(&c.oid)));
        graph_args.push("--".into());
        let graph = self.historical_read(&graph_args, policy, cancel)?;
        self.verify(policy, cancel)?;
        Ok(History {
            repository: self.clone(),
            commits,
            graph,
            metadata_output,
        })
    }
    pub fn commit_changes(
        &self,
        commit_oid: &str,
        parent_index: usize,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<CommitChanges, Error> {
        check_oid(commit_oid.as_bytes())?;
        let mut args = vec!["show".into(), "--no-patch".into()];
        args.extend(log_args());
        args.extend([commit_oid.into(), "--".into()]);
        let meta = self.historical_read(&args, policy, cancel)?;
        let mut parsed = commits(&meta.stdout)?;
        if parsed.len() != 1 {
            return Err(Error::MalformedOutput("one commit required"));
        }
        let commit = parsed.remove(0);
        if commit.oid != commit_oid {
            return Err(Error::StalePreview);
        }
        let parent = if commit.parents.is_empty() {
            if parent_index != 0 {
                return Err(Error::InvalidInput("root parent"));
            }
            None
        } else {
            Some(
                commit
                    .parents
                    .get(parent_index)
                    .ok_or(Error::InvalidInput("parent index"))?
                    .clone(),
            )
        };
        let mut args: Vec<OsString> = [
            "diff-tree",
            "--no-commit-id",
            "--raw",
            "--no-abbrev",
            "--no-ext-diff",
            "--no-textconv",
            "-r",
            "-z",
            "-M",
        ]
        .into_iter()
        .map(Into::into)
        .collect();
        if let Some(parent) = &parent {
            args.push(parent.into());
        } else {
            args.push("--root".into());
        }
        args.extend([commit_oid.into(), "--".into()]);
        let output = self.historical_read(&args, policy, cancel)?;
        let changes = parse_changes(&output.stdout)?;
        self.verify(policy, cancel)?;
        Ok(CommitChanges {
            repository: self.clone(),
            commit,
            parent,
            changes,
            output,
            metadata_output: meta,
        })
    }
}
fn parse_changes(bytes: &[u8]) -> Result<Vec<HistoricalChange>, Error> {
    let mut fields = bytes.split(|b| *b == 0);
    let mut result = Vec::new();
    while let Some(header) = fields.next() {
        if header.is_empty() {
            if fields.next().is_some() {
                return Err(Error::MalformedOutput("raw diff tail"));
            }
            break;
        }
        if result.len() >= 2000 {
            return Err(Error::InvalidInput("historical change limit: 2000"));
        }
        let parts: Vec<_> = header
            .strip_prefix(b":")
            .ok_or(Error::MalformedOutput("raw diff header"))?
            .split(|b| *b == b' ')
            .collect();
        if parts.len() != 5 {
            return Err(Error::MalformedOutput("raw diff fields"));
        }
        let mode = |v: &[u8]| -> Result<String, Error> {
            if v.len() != 6 || !v.iter().all(|b| matches!(b, b'0'..=b'7')) {
                return Err(Error::MalformedOutput("object mode"));
            }
            Ok(String::from_utf8(v.to_vec()).unwrap())
        };
        let object = |v: &[u8]| -> Result<Option<String>, Error> {
            check_oid(v)?;
            if v.iter().all(|b| *b == b'0') {
                Ok(None)
            } else {
                Ok(Some(oid(v)?))
            }
        };
        let status = std::str::from_utf8(parts[4])
            .map_err(|_| Error::MalformedOutput("change status"))?
            .to_owned();
        if !matches!(
            status.as_bytes().first(),
            Some(b'A' | b'D' | b'M' | b'T' | b'R' | b'C')
        ) {
            return Err(Error::MalformedOutput("change kind"));
        }
        let old_path = RepoPath::new(
            fields
                .next()
                .ok_or(Error::MalformedOutput("change path"))?
                .to_vec(),
        )?;
        let new_path = if status.starts_with(['R', 'C']) {
            RepoPath::new(
                fields
                    .next()
                    .ok_or(Error::MalformedOutput("rename target"))?
                    .to_vec(),
            )?
        } else {
            old_path.clone()
        };
        result.push(HistoricalChange {
            old_path,
            new_path,
            old_mode: mode(parts[0])?,
            new_mode: mode(parts[1])?,
            status,
            old_oid: object(parts[2])?,
            new_oid: object(parts[3])?,
        });
    }
    Ok(result)
}
impl CommitChanges {
    pub fn changes(&self) -> &[HistoricalChange] {
        &self.changes
    }
    pub fn pair(
        &self,
        index: usize,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<HistoricalPair, Error> {
        let change = self
            .changes
            .get(index)
            .ok_or(Error::InvalidInput("historical file index"))?;
        let mut warnings = vec![
            self.metadata_output.stderr.clone(),
            self.output.stderr.clone(),
        ];
        let mut load = |object: &Option<String>, mode: &str| -> Result<HistoricalBlob, Error> {
            let bytes = if let Some(oid) = object {
                if mode == "160000" {
                    Vec::new()
                } else {
                    let size = self.repository.historical_read(
                        &["cat-file".into(), "-s".into(), oid.into()],
                        policy,
                        cancel,
                    )?;
                    warnings.push(size.stderr);
                    let size = std::str::from_utf8(&size.stdout)
                        .ok()
                        .and_then(|s| s.trim().parse::<usize>().ok())
                        .ok_or(Error::MalformedOutput("blob size"))?;
                    if size > MAX_BLOB {
                        return Err(Error::InvalidInput("historical blob limit: 1 MiB"));
                    }
                    let out = self.repository.historical_read(
                        &["cat-file".into(), "blob".into(), oid.into()],
                        Policy {
                            stdout_bytes: MAX_BLOB,
                            ..policy
                        },
                        cancel,
                    )?;
                    warnings.push(out.stderr);
                    if out.stdout.len() != size {
                        return Err(Error::StalePreview);
                    }
                    out.stdout
                }
            } else {
                Vec::new()
            };
            Ok(HistoricalBlob {
                oid: object.clone(),
                mode: mode.into(),
                bytes,
            })
        };
        let before = load(&change.old_oid, &change.old_mode)?;
        let after = load(&change.new_oid, &change.new_mode)?;
        self.repository.verify(policy, cancel)?;
        Ok(HistoricalPair {
            before,
            after,
            warnings,
        })
    }
}

impl History {
    pub fn commit_changes(
        &self,
        index: usize,
        parent: usize,
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<CommitChanges, Error> {
        let commit = self
            .commits
            .get(index)
            .ok_or(Error::InvalidInput("historical commit index"))?;
        self.repository
            .commit_changes(&commit.oid, parent, policy, cancel)
    }
}
