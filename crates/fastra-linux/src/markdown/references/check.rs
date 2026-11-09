use super::{
    local_path::LocalPaths,
    parser::{self, Destination, Parsed, Reference},
};
use fastra_core::Cancellation;
use std::{
    collections::{HashMap, HashSet},
    fs,
    os::{
        fd::AsRawFd,
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime},
};

#[derive(Clone, Debug)]
pub(super) struct Source {
    pub id: usize,
    pub document: Option<usize>,
    pub revision: u64,
    pub path: Option<PathBuf>,
    pub title: String,
    pub content: String,
    pub snapshot: Option<fastra_io::ReadSnapshot>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Status {
    Valid,
    Missing,
    Ambiguous,
    Unverified,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Notice {
    Limit,
    Files,
    References,
    Budget,
    UnsupportedHtml,
    ProjectList,
    Read,
    LocalOnly,
    Changed,
    Encoding,
    Invalid,
    NeedsFile,
    MissingFile,
    Special,
    MarkdownOnly,
    Present,
    MissingAnchor,
    Ambiguous,
    AnchorPresent,
    IncompleteAnchors,
    SourceUnknown,
    Cancelled,
}
#[derive(Debug)]
pub(super) struct Finding {
    pub source: usize,
    pub reference: Reference,
    pub status: Status,
    pub message: Notice,
}
#[derive(Debug)]
pub(super) struct Issue {
    pub path: Option<PathBuf>,
    pub message: Notice,
}
#[derive(Debug)]
pub(super) struct Report {
    pub sources: Vec<Source>,
    pub findings: Vec<Finding>,
    pub issues: Vec<Issue>,
    pub remote_count: usize,
    pub complete: bool,
    pub read_bytes: usize,
    pub project: Option<PathBuf>,
    pub completed: SystemTime,
}
impl Default for Report {
    fn default() -> Self {
        Self {
            sources: vec![],
            findings: vec![],
            issues: vec![],
            remote_count: 0,
            complete: true,
            read_bytes: 0,
            project: None,
            completed: SystemTime::now(),
        }
    }
}
pub(super) struct Options {
    pub files: usize,
    pub bytes: usize,
    pub references: usize,
    pub anchors: usize,
    pub exclusions: Vec<String>,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            files: 200,
            bytes: 64 * 1024 * 1024,
            references: 10_000,
            anchors: 10_000,
            exclusions: vec![],
        }
    }
}
struct Check<'a> {
    local: LocalPaths,
    cancel: &'a Cancellation,
    options: Options,
    report: Report,
    parsed: Vec<Parsed>,
    by_path: HashMap<PathBuf, usize>,
    by_identity: HashMap<(u64, u64), usize>,
    failed: HashMap<PathBuf, Notice>,
    charged: HashSet<usize>,
    files: usize,
    references: usize,
    anchors: usize,
    next: usize,
}
impl Check<'_> {
    fn issue(&mut self, message: Notice, path: Option<PathBuf>) {
        self.report.complete = false;
        if self.report.issues.len() < 20 {
            self.report.issues.push(Issue { path, message });
        }
    }
    fn resolve(&self, path: &Path) -> Result<PathBuf, Notice> {
        self.local.resolve(path, self.cancel).map_err(|e| match e {
            super::local_path::Error::Cancelled => Notice::Cancelled,
            super::local_path::Error::NonLocal | super::local_path::Error::InvalidTable => {
                Notice::LocalOnly
            }
            super::local_path::Error::InvalidPath => Notice::Invalid,
            super::local_path::Error::Io(error) => {
                let _ = error.kind();
                Notice::Read
            }
        })
    }
    fn read(&mut self, path: &Path) -> Result<Source, Notice> {
        self.cancel.check().map_err(|_| Notice::Cancelled)?;
        let path = self.resolve(path)?;
        let remaining = self
            .options
            .bytes
            .saturating_sub(self.report.read_bytes)
            .min(parser::MAX_SOURCE);
        let snapshot = fastra_io::ReadSnapshot::read_bounded(&path, remaining, self.cancel).map_err(
            |e| match e {
                fastra_io::Error::Core(fastra_core::Error::Cancelled) => Notice::Cancelled,
                fastra_io::Error::Limit => Notice::Budget,
                fastra_io::Error::Stale => Notice::Changed,
                _ => Notice::Read,
            },
        )?;
        self.report.read_bytes += snapshot.bytes().len();
        let decoded =
            fastra_core::encoding::decode(snapshot.bytes(), None).map_err(|_| Notice::Encoding)?;
        let id = self.next;
        self.next += 1;
        self.charged.insert(id);
        Ok(Source {
            id,
            document: None,
            revision: 0,
            title: path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default(),
            path: Some(path),
            content: decoded.text().into(),
            snapshot: Some(snapshot),
        })
    }
    fn parse(&mut self, source: &Source) -> Result<usize, Notice> {
        if self.files >= self.options.files {
            return Err(Notice::Files);
        }
        let bytes = source.content.len();
        if bytes > parser::MAX_SOURCE
            || self.report.read_bytes > self.options.bytes
            || !self.charged.contains(&source.id)
                && bytes > self.options.bytes.saturating_sub(self.report.read_bytes)
        {
            return Err(Notice::Budget);
        }
        if self.charged.insert(source.id) {
            self.report.read_bytes += bytes;
        }
        self.files += 1;
        let parsed = parser::parse(
            &source.content,
            self.options.references.saturating_sub(self.references),
            self.options.anchors.saturating_sub(self.anchors),
            self.cancel,
        )
        .map_err(|e| match e {
            parser::Error::Cancelled => Notice::Cancelled,
            _ => Notice::Limit,
        })?;
        self.references += parsed.references.len();
        self.anchors += parsed.anchor_count;
        if parsed.incomplete {
            self.issue(Notice::References, source.path.clone());
        }
        if parsed.unsupported_html {
            self.issue(Notice::UnsupportedHtml, source.path.clone());
        }
        let index = self.parsed.len();
        self.parsed.push(parsed);
        if let Some(path) = source.path.as_ref().and_then(|p| self.resolve(p).ok()) {
            if let Ok(metadata) = self.local.metadata(&path, self.cancel) {
                self.by_identity
                    .insert((metadata.dev(), metadata.ino()), index);
            }
            self.by_path.insert(path, index);
        }
        Ok(index)
    }
    fn anchor(&self, value: Option<&str>, index: usize) -> (Status, Notice) {
        let Some(value) = value.filter(|s| !s.is_empty()) else {
            return (Status::Valid, Notice::Present);
        };
        let Some(parsed) = self.parsed.get(index) else {
            return (Status::Unverified, Notice::SourceUnknown);
        };
        if parsed.unsupported_html {
            return (Status::Unverified, Notice::UnsupportedHtml);
        }
        if !parsed.anchors_complete {
            return (Status::Unverified, Notice::IncompleteAnchors);
        }
        match parsed.anchors.get(value).copied().unwrap_or(0) {
            0 => (Status::Missing, Notice::MissingAnchor),
            1 => (Status::Valid, Notice::AnchorPresent),
            _ => (Status::Ambiguous, Notice::Ambiguous),
        }
    }
    fn target(&mut self, path: &Path, anchor: Option<&str>) -> Result<(Status, Notice), Notice> {
        let path = self.resolve(path)?;
        let metadata = match self.local.metadata(&path, self.cancel) {
            Ok(m) => m,
            Err(super::local_path::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                return Ok((Status::Missing, Notice::MissingFile))
            }
            Err(_) => return Err(Notice::Read),
        };
        if !metadata.is_file() && !metadata.is_dir() {
            return Err(Notice::Special);
        }
        if anchor.is_none_or(str::is_empty) {
            return Ok((Status::Valid, Notice::Present));
        }
        let known = self.by_path.get(&path).copied().or_else(|| {
            self.by_identity
                .get(&(metadata.dev(), metadata.ino()))
                .copied()
        });
        if !metadata.is_file() || known.is_none() && !markdown(&path) {
            return Err(Notice::MarkdownOnly);
        }
        let index = if let Some(index) = known {
            index
        } else {
            if let Some(error) = self.failed.get(&path) {
                return Err(*error);
            }
            if self.files >= self.options.files {
                return Err(Notice::Files);
            }
            let source = self.read(&path).and_then(|s| self.parse(&s));
            match source {
                Ok(i) => i,
                Err(e) => {
                    self.failed.insert(path, e);
                    return Err(e);
                }
            }
        };
        Ok(self.anchor(anchor, index))
    }
}
fn markdown(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()).is_some_and(|s| {
        matches!(
            s.to_ascii_lowercase().as_str(),
            "md" | "markdown" | "mdown" | "mkd"
        )
    })
}
fn package(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()).is_some_and(|s| {
        matches!(
            s.to_ascii_lowercase().as_str(),
            "app"
                | "bundle"
                | "framework"
                | "plugin"
                | "xcodeproj"
                | "xcworkspace"
                | "playground"
                | "rtfd"
                | "pages"
                | "numbers"
                | "key"
        )
    })
}
fn candidates(
    root: &Path,
    local: &LocalPaths,
    exclude: &fastra_search::Exclusions,
    opened: &HashMap<PathBuf, Source>,
    cancel: &Cancellation,
) -> Result<Vec<PathBuf>, Notice> {
    let began = Instant::now();
    let mut pending = vec![(root.to_path_buf(), 0)];
    let mut files = vec![];
    let mut bytes = 0;
    let mut entries = 0;
    while let Some((directory, depth)) = pending.pop() {
        cancel.check().map_err(|_| Notice::Cancelled)?;
        if began.elapsed() > Duration::from_secs(15) || depth > 128 {
            return Err(Notice::ProjectList);
        }
        let directory = local
            .resolve(&directory, cancel)
            .map_err(|_| Notice::LocalOnly)?;
        fastra_io::check_runtime_path(&directory).map_err(|_| Notice::Read)?;
        let handle = local
            .directory(&directory, cancel)
            .map_err(|_| Notice::Read)?;
        let reader = fs::read_dir(format!("/proc/self/fd/{}", handle.as_raw_fd()))
            .map_err(|_| Notice::Read)?;
        for entry in reader {
            cancel.check().map_err(|_| Notice::Cancelled)?;
            if began.elapsed() > Duration::from_secs(15) {
                return Err(Notice::ProjectList);
            }
            let entry = entry.map_err(|_| Notice::Read)?;
            entries += 1;
            bytes += directory.as_os_str().len() + 1 + entry.file_name().as_bytes().len();
            if entries > 100_000 || bytes > 4 * 1024 * 1024 {
                return Err(Notice::ProjectList);
            }
            if entry.file_name().as_bytes().starts_with(b".") {
                continue;
            }
            let path = directory.join(entry.file_name());
            let relative = path.strip_prefix(root).map_err(|_| Notice::ProjectList)?;
            if exclude.matches(relative).map_err(|_| Notice::ProjectList)? {
                continue;
            }
            // Vor Metadatenzugriffen auch einzelne Mountpunkte prüfen; Links
            // gehören weder als Datei noch als Verzeichnis in die Projektliste.
            let metadata = local
                .metadata(&path, cancel)
                .map_err(|_| Notice::LocalOnly)?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            let checked = path.clone();
            if metadata.is_dir() && !package(&path) {
                pending.push((checked, depth + 1));
            } else if metadata.is_file() && (markdown(&path) || opened.contains_key(&checked)) {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}
pub(super) fn check(
    document: Source,
    open: Vec<Source>,
    project: Option<PathBuf>,
    options: Options,
    cancel: &Cancellation,
    mut progress: impl FnMut(usize, usize, &str),
) -> Result<Report, Notice> {
    cancel.check().map_err(|_| Notice::Cancelled)?;
    let next = open
        .iter()
        .chain(std::iter::once(&document))
        .map(|s| s.id)
        .max()
        .unwrap_or(0)
        + 1;
    let local = LocalPaths::current(cancel).map_err(|_| Notice::LocalOnly)?;
    let mut check = Check {
        local,
        cancel,
        options,
        report: Report::default(),
        parsed: vec![],
        by_path: HashMap::new(),
        by_identity: HashMap::new(),
        failed: HashMap::new(),
        charged: HashSet::new(),
        files: 0,
        references: 0,
        anchors: 0,
        next,
    };
    let mut sources = vec![];
    if let Some(root) = project {
        let listed = (|| {
            let root = check.resolve(&root)?;
            check.report.project = Some(root.clone());
            let exclusions = fastra_search::Exclusions::new(&check.options.exclusions, cancel)
                .map_err(|_| Notice::ProjectList)?;
            let mut opened = HashMap::new();
            for source in open.into_iter().chain(std::iter::once(document)) {
                if let Some(path) = source.path.as_ref().and_then(|p| check.resolve(p).ok()) {
                    opened.insert(path, source);
                }
            }
            let paths = candidates(&root, &check.local, &exclusions, &opened, cancel)?;
            let mut bytes = 0;
            for path in paths {
                cancel.check().map_err(|_| Notice::Cancelled)?;
                if sources.len() >= check.options.files {
                    check.issue(Notice::Files, None);
                    break;
                }
                let source = opened.remove(&path).map_or_else(|| check.read(&path), Ok);
                match source {
                    Ok(source) => {
                        if source.content.len() > check.options.bytes.saturating_sub(bytes)
                            || !check.charged.contains(&source.id)
                                && source.content.len()
                                    > check.options.bytes.saturating_sub(check.report.read_bytes)
                        {
                            check.issue(Notice::Budget, None);
                            break;
                        }
                        bytes += source.content.len();
                        if check.charged.insert(source.id) {
                            check.report.read_bytes += source.content.len();
                        }
                        sources.push(source);
                    }
                    Err(Notice::Cancelled) => return Err(Notice::Cancelled),
                    Err(e) => check.issue(e, Some(path)),
                }
            }
            Ok(())
        })();
        match listed {
            Err(Notice::Cancelled) => return Err(Notice::Cancelled),
            Err(e) => check.issue(e, Some(root)),
            Ok(()) => {}
        }
    } else {
        sources.push(document);
    }
    let mut indices = HashMap::new();
    for source in sources {
        cancel.check().map_err(|_| Notice::Cancelled)?;
        progress(check.report.sources.len(), 0, &source.title);
        match check.parse(&source) {
            Ok(index) => {
                indices.insert(source.id, index);
                check.report.sources.push(source);
            }
            Err(Notice::Cancelled) => return Err(Notice::Cancelled),
            Err(e) => check.issue(e, source.path),
        }
    }
    let mut count = 0;
    // Quellen bleiben bis zum Ende unveränderliche Berichtsbasis; Zielanalysen
    // werden separat gehalten und können keine zusätzlichen Quellzeilen erzeugen.
    let sources = std::mem::take(&mut check.report.sources);
    for source in &sources {
        let index = indices[&source.id];
        let references = check.parsed[index].references.clone();
        for reference in references {
            cancel.check().map_err(|_| Notice::Cancelled)?;
            count += 1;
            let result = match parser::destination(&reference.destination, source.path.as_deref()) {
                Destination::Remote => {
                    check.report.remote_count += 1;
                    continue;
                }
                Destination::Invalid => Err(Notice::Invalid),
                Destination::Local(path, anchor) => {
                    if reference.destination.is_empty() || reference.destination.starts_with('#') {
                        Ok(check.anchor(anchor.as_deref(), index))
                    } else if let Some(path) = path {
                        check.target(&path, anchor.as_deref())
                    } else {
                        Err(Notice::NeedsFile)
                    }
                }
            };
            let (status, message) = match result {
                Ok(value) => value,
                Err(Notice::Cancelled) => return Err(Notice::Cancelled),
                Err(error) => (Status::Unverified, error),
            };
            if status == Status::Unverified {
                check.report.complete = false;
            }
            check.report.findings.push(Finding {
                source: source.id,
                reference,
                status,
                message,
            });
            if count % 50 == 0 {
                progress(sources.len(), count, &source.title);
            }
        }
    }
    check.report.sources = sources;
    check.report.completed = SystemTime::now();
    cancel.check().map_err(|_| Notice::Cancelled)?;
    Ok(check.report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source(id: usize, path: Option<PathBuf>, content: &str) -> Source {
        Source {
            id,
            document: Some(id),
            revision: 1,
            path,
            title: format!("source{id}"),
            content: content.into(),
            snapshot: None,
        }
    }
    fn directory() -> tempfile::TempDir {
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        tempfile::tempdir_in(root).unwrap()
    }
    fn run(
        document: Source,
        open: Vec<Source>,
        project: Option<PathBuf>,
        options: Options,
    ) -> Report {
        check(
            document,
            open,
            project,
            options,
            &Cancellation::default(),
            |_, _, _| {},
        )
        .unwrap()
    }
    #[test]
    fn project_hardlinks_are_read_with_each_paths_relative_reference_context() {
        let d = directory();
        let root = d.path();
        for name in ["a", "b"] { fs::create_dir(root.join(name)).unwrap(); }
        let text = "# Linked\n[relative](only-here.txt)\n";
        fs::write(root.join("a/source.md"), text).unwrap();
        fs::hard_link(root.join("a/source.md"), root.join("b/source.md")).unwrap();
        fs::write(root.join("a/only-here.txt"), "present").unwrap();
        fs::write(root.join("root.md"), "# Root\n").unwrap();
        let report = run(source(0, Some(root.join("root.md")), "# Root\n"), vec![], Some(root.to_path_buf()), Options::default());
        assert!(report.complete, "{:?}", report.issues);
        assert_eq!(report.findings.len(), 2);
        for finding in &report.findings {
            let source = report.sources.iter().find(|source| source.id == finding.source).unwrap();
            let path = source.path.as_ref().unwrap();
            assert_eq!(finding.status, if path.ends_with("a/source.md") { Status::Valid } else { Status::Missing });
            assert_eq!(source.snapshot.as_ref().unwrap().bytes(), text.as_bytes());
        }
        assert_eq!(fs::read_to_string(root.join("a/source.md")).unwrap(), text);
        assert_eq!(fs::read_to_string(root.join("b/source.md")).unwrap(), text);
    }
    #[test]
    fn file_urls_preserve_encoded_separator_filenames_and_ignore_query_metadata() {
        let d = directory();
        let root = d.path();
        for name in ["a%2fb.md", "target.md", "q?x.md"] {
            fs::write(root.join(name), "# Target").unwrap();
        }
        let text=format!("[a](file://localhost{}/a%2fb.md#target) [b](file://info@localhost:123{}/target.md?cache=no#target) [c](file://localhost{}/q%3Fx.md#target) [d](target.md?cache=no)",root.display(),root.display(),root.display());
        let report = run(
            source(0, Some(root.join("source.md")), &text),
            vec![],
            None,
            Options::default(),
        );
        assert!(report.complete);
        assert_eq!(
            report.findings.iter().map(|f| f.status).collect::<Vec<_>>(),
            vec![Status::Valid, Status::Valid, Status::Valid, Status::Missing]
        );
        for name in ["a%2fb.md", "target.md", "q?x.md"] {
            assert_eq!(fs::read_to_string(root.join(name)).unwrap(), "# Target");
        }
    }
    #[test]
    fn anchors_files_images_and_utf16_targets_use_readonly_snapshots() {
        let d = directory();
        let root = d.path();
        let target = "# Gleich\n# Gleich\n# Einzig\n<a id='html'></a>\n";
        let mut utf16 = vec![0xff, 0xfe];
        for c in target.encode_utf16() {
            utf16.extend(c.to_le_bytes());
        }
        fs::write(root.join("ziel.md"), &utf16).unwrap();
        fs::write(root.join("image#x.png"), [0, 1, 255]).unwrap();
        std::os::unix::fs::symlink("ziel.md", root.join("alias.md")).unwrap();
        let input="[1](ziel.md#gleich) [2](ziel.md#einzig) [3](alias.md#html) [4](ziel.md#fehlt) ![5](image%23x.png) [6](missing.md) [7](https://example.invalid/)";
        let p = run(
            source(0, Some(root.join("a.md")), input),
            vec![],
            None,
            Options::default(),
        );
        assert!(p.complete);
        assert_eq!(p.remote_count, 1);
        assert_eq!(
            p.findings.iter().map(|f| f.status).collect::<Vec<_>>(),
            vec![
                Status::Ambiguous,
                Status::Valid,
                Status::Valid,
                Status::Missing,
                Status::Valid,
                Status::Missing
            ]
        );
        assert_eq!(fs::read(root.join("ziel.md")).unwrap(), utf16);
        assert_eq!(fs::read(root.join("image#x.png")).unwrap(), [0, 1, 255]);
    }
    #[test]
    fn project_open_buffers_override_disk_and_scope_never_includes_outside_or_excluded() {
        let d = directory();
        let root = d.path();
        fs::create_dir(root.join("build")).unwrap();
        fs::create_dir(root.join("Fixture.app")).unwrap();
        fs::write(root.join("a.md"), "[link](b.md#fresh)").unwrap();
        fs::write(root.join("b.md"), "# Old").unwrap();
        fs::write(root.join("manual.txt"), "[self](manual.txt#fresh)\n# Fresh").unwrap();
        for path in [".hidden.md", "build/x.md", "Fixture.app/x.md"] {
            fs::write(root.join(path), "[bad](missing.md)").unwrap();
        }
        std::os::unix::fs::symlink("a.md", root.join("alias.md")).unwrap();
        let open = vec![
            source(1, Some(root.join("b.md")), "# Fresh"),
            source(
                2,
                Some(root.join("manual.txt")),
                "[self](manual.txt#fresh)\n# Fresh",
            ),
        ];
        let options = Options {
            exclusions: vec!["build".into()],
            ..Default::default()
        };
        let p = run(
            source(0, Some(root.join("build/x.md")), "[bad](missing.md)"),
            open,
            Some(root.into()),
            options,
        );
        assert!(p.complete);
        assert_eq!(p.sources.len(), 3);
        assert_eq!(p.findings.len(), 2);
        assert!(p.findings.iter().all(|f| f.status == Status::Valid));
        assert_eq!(fs::read_to_string(root.join("b.md")).unwrap(), "# Old");
        let p = run(
            source(0, Some(root.join("build/x.md")), "[bad](missing.md)"),
            vec![],
            None,
            Options::default(),
        );
        assert_eq!(p.findings.len(), 1);
        let p = run(
            source(
                0,
                Some(root.parent().unwrap().join("outside.md")),
                "[bad](missing.md)",
            ),
            vec![],
            Some(root.into()),
            Options {
                files: 1,
                exclusions: vec!["build".into()],
                ..Default::default()
            },
        );
        assert!(!p.complete);
        assert_eq!(p.sources.len(), 1);
        assert!(p.sources[0].path.as_ref().unwrap().starts_with(root));
    }
    #[test]
    fn unverified_is_visible_and_failed_decoding_is_charged_once() {
        let d = directory();
        let root = d.path();
        fs::write(root.join("bad.md"), [0, 1, 2, 3, 4, 5]).unwrap();
        let input = "[x](bad.md#a) [x](bad.md#b)";
        let p = run(
            source(0, Some(root.join("a.md")), input),
            vec![],
            None,
            Options::default(),
        );
        assert!(!p.complete);
        assert_eq!(p.read_bytes, input.len() + 6);
        assert!(p.findings.iter().all(|f| f.message == Notice::Encoding));
        let p = run(
            source(
                0,
                None,
                "[a](relative.md) [b](#missing)\n\n<div id=unsupported></div>",
            ),
            vec![],
            None,
            Options::default(),
        );
        assert!(!p.complete);
        assert_eq!(p.findings[0].message, Notice::NeedsFile);
        assert_eq!(p.findings[1].status, Status::Unverified);
        let p = run(
            source(0, None, "# Self\n[self](#self)"),
            vec![],
            None,
            Options {
                bytes: 2,
                ..Default::default()
            },
        );
        assert!(!p.complete);
        assert!(p.sources.is_empty());
    }
    #[test]
    fn target_and_anchor_budgets_and_cancel_are_explicit() {
        let d = directory();
        let root = d.path();
        fs::write(root.join("target.md"), "# Target").unwrap();
        let p = run(
            source(0, Some(root.join("a.md")), "[x](target.md#target)"),
            vec![],
            None,
            Options {
                files: 1,
                ..Default::default()
            },
        );
        assert!(!p.complete);
        assert_eq!(p.findings[0].message, Notice::Files);
        let p = run(
            source(0, None, "# !\n# !\n# Real\n[x](#real)"),
            vec![],
            None,
            Options {
                anchors: 1,
                ..Default::default()
            },
        );
        assert!(!p.complete);
        assert_eq!(p.findings[0].message, Notice::IncompleteAnchors);
        let cancel = Cancellation::default();
        cancel.cancel();
        assert_eq!(
            check(
                source(0, None, ""),
                vec![],
                None,
                Options::default(),
                &cancel,
                |_, _, _| {}
            )
            .unwrap_err(),
            Notice::Cancelled
        );
    }
}
