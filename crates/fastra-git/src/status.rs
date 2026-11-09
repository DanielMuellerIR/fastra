use crate::{Error, RepoPath};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangeKind {
    Ordinary,
    RenameOrCopy { score: Vec<u8>, original: RepoPath },
    Unmerged,
    Untracked,
    Ignored,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub path: RepoPath,
    /// Unveränderte Porcelain-Spalten: Index und Working Tree, inklusive Konflikte.
    pub xy: [u8; 2],
    pub kind: ChangeKind,
    /// Vollständiger Datensatz einschließlich Submodul-, Modus- und OID-Feldern.
    pub raw_record: Vec<u8>,
}
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub head_oid: Option<Vec<u8>>,
    pub branch: Option<Vec<u8>>,
    pub detached: bool,
    pub upstream: Option<Vec<u8>>,
    pub ahead: u64,
    pub behind: u64,
    pub changes: Vec<Change>,
}
fn fields(record: &[u8], count: usize) -> Result<Vec<&[u8]>, Error> {
    let fields: Vec<_> = record.splitn(count, |b| *b == b' ').collect();
    if fields.len() != count || fields[0].len() != 1 {
        return Err(Error::MalformedOutput("incomplete status record"));
    }
    Ok(fields)
}
pub fn parse_status(output: &[u8]) -> Result<Status, Error> {
    if !output.is_empty() && !output.ends_with(&[0]) {
        return Err(Error::MalformedOutput("unterminated status record"));
    }
    let mut records = output.split(|b| *b == 0).peekable();
    let mut status = Status::default();
    while let Some(record) = records.next() {
        if record.is_empty() {
            if records.peek().is_some() {
                return Err(Error::MalformedOutput("empty status record"));
            }
            break;
        }
        if let Some(value) = record.strip_prefix(b"# branch.oid ") {
            if value != b"(initial)" {
                crate::check_oid(value)?;
                status.head_oid = Some(value.to_vec());
            }
        } else if let Some(value) = record.strip_prefix(b"# branch.head ") {
            status.detached = value == b"(detached)";
            if !status.detached && value != b"(unknown)" {
                status.branch = Some(value.to_vec());
            }
        } else if let Some(value) = record.strip_prefix(b"# branch.upstream ") {
            status.upstream = Some(value.to_vec());
        } else if let Some(value) = record.strip_prefix(b"# branch.ab ") {
            let pair: Vec<_> = value.split(|b| *b == b' ').collect();
            if pair.len() != 2 || pair[0].first() != Some(&b'+') || pair[1].first() != Some(&b'-') {
                return Err(Error::MalformedOutput("invalid ahead/behind"));
            }
            let number = |bytes: &[u8]| {
                std::str::from_utf8(bytes)
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .ok_or(Error::MalformedOutput("invalid ahead/behind number"))
            };
            status.ahead = number(&pair[0][1..])?;
            status.behind = number(&pair[1][1..])?;
        } else if record.starts_with(b"# ") {
            continue;
        } else {
            let (path, xy, kind) = match record[0] {
                b'1' | b'2' | b'u' => {
                    let count = match record[0] {
                        b'1' => 9,
                        b'2' => 10,
                        _ => 11,
                    };
                    let values = fields(record, count)?;
                    let xy = <[u8; 2]>::try_from(values[1])
                        .map_err(|_| Error::MalformedOutput("invalid XY status"))?;
                    if !xy.iter().all(|b| b".MTADRCU".contains(b)) {
                        return Err(Error::MalformedOutput("unknown XY status"));
                    }
                    let kind = match record[0] {
                        b'1' => ChangeKind::Ordinary,
                        b'2' => ChangeKind::RenameOrCopy {
                            score: values[8].to_vec(),
                            original: RepoPath::new(
                                records
                                    .next()
                                    .ok_or(Error::MalformedOutput("missing rename source"))?
                                    .to_vec(),
                            )?,
                        },
                        _ => ChangeKind::Unmerged,
                    };
                    (RepoPath::new(values[count - 1].to_vec())?, xy, kind)
                }
                b'?' | b'!' => {
                    let values = fields(record, 2)?;
                    (
                        RepoPath::new(values[1].to_vec())?,
                        [record[0]; 2],
                        if record[0] == b'?' {
                            ChangeKind::Untracked
                        } else {
                            ChangeKind::Ignored
                        },
                    )
                }
                _ => return Err(Error::MalformedOutput("unknown status record")),
            };
            status.changes.push(Change {
                path,
                xy,
                kind,
                raw_record: record.to_vec(),
            });
        }
    }
    Ok(status)
}
