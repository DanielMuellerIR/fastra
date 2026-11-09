//! Begrenzte Ordnersuche mit unveränderlicher Trefferbasis und expliziter Freigabe.
#![cfg(target_os = "linux")]
use fastra_core::{
    encoding, Cancellation, Limits, PreparedSearch, Preview, SearchFlags, SearchMode, SearchRequest,
};
use fastra_io::{Change, Snapshot, Transaction};
use std::sync::Arc;
use std::{
    collections::HashSet,
    ffi::{CString, OsStr},
    fs::{self, File, Metadata},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Component, Path, PathBuf},
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Core(fastra_core::Error),
    File(fastra_io::Error),
    Stale,
    Limit,
    InvalidRoots,
    InvalidApproval,
    Workflow {
        path: PathBuf,
        error: fastra_workflow::Error,
    },
    Encoding {
        path: PathBuf,
        error: encoding::EncodingError,
    },
    WorkflowInput {
        path: PathBuf,
        message: String,
    },
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<fastra_core::Error> for Error {
    fn from(e: fastra_core::Error) -> Self {
        Self::Core(e)
    }
}
impl From<fastra_io::Error> for Error {
    fn from(e: fastra_io::Error) -> Self {
        Self::File(e)
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
mod selection;
type Result<T> = std::result::Result<T, Error>;

#[derive(Clone)]
pub struct Request {
    pub roots: Vec<PathBuf>,
    pub search: SearchRequest,
    pub flags: SearchFlags,
    pub exclusions: Vec<String>,
    pub include_hidden: bool,
    pub known_text_only: bool,
}
/// Ein expliziter Dateisatz oder eine Ordnerwurzel; dieselben gebundenen Reader wie die Suche.
/// Fehler einer ausgewählten Eingabe verweigern den vollständigen Workflowplan.
#[derive(Clone)]
pub struct WorkflowRequest {
    pub roots: Vec<PathBuf>,
    pub files: Vec<PathBuf>,
    pub exclusions: Vec<String>,
    pub known_text_only: bool,
    pub definition: fastra_workflow::Workflow,
    pub locale: Option<fastra_core::text_operations::TitlecaseLocale>,
}
#[derive(Clone, Debug)]
struct WorkflowContext {
    definition: fastra_workflow::Workflow,
    locale: Option<fastra_core::text_operations::TitlecaseLocale>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    LinkOrSpecial,
    Binary,
    TooLarge,
    LongLine,
    NonUnicodePath,
    UnsupportedFile,
}
#[derive(Debug)]
pub struct Skipped {
    pub path: PathBuf,
    pub reason: SkipReason,
}
pub struct FilePreview {
    snapshot: Snapshot,
    preview: Arc<Preview>,
    workflow: Option<Arc<fastra_workflow::Preview>>,
}
impl std::fmt::Debug for FilePreview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FilePreview")
            .field("snapshot", &self.snapshot)
            .field("preview", &self.preview)
            .finish_non_exhaustive()
    }
}
impl FilePreview {
    pub fn snapshot_binding(&self) -> std::result::Result<[u8; 32], fastra_io::Error> {
        self.snapshot.binding_digest()
    }

    pub fn workflow_preview(&self) -> Option<&Arc<fastra_workflow::Preview>> {
        self.workflow.as_ref()
    }
    pub fn path(&self) -> PathBuf {
        self.snapshot.path()
    }
    pub fn preview(&self) -> &Preview {
        &self.preview
    }
    pub fn shared_preview(&self) -> Arc<Preview> {
        self.preview.clone()
    }
    pub fn after(&self, approved: &[usize], cancel: &Cancellation) -> Result<String> {
        Ok(self.preview.apply(
            self.preview.source(),
            0,
            self.preview.generation(),
            approved,
            cancel,
        )?)
    }
}
#[derive(Debug)]
struct Directory {
    path: PathBuf,
    handle: File,
    stamp: Stamp,
}
#[derive(Debug, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
fn stamp(m: &Metadata) -> Stamp {
    Stamp {
        device: m.dev(),
        inode: m.ino(),
        mtime: m.mtime(),
        mtime_ns: m.mtime_nsec(),
        ctime: m.ctime(),
        ctime_ns: m.ctime_nsec(),
    }
}
fn owned(fd: i32) -> Result<File> {
    if fd < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}
fn open_child(parent: &File, name: &OsStr) -> Result<File> {
    fastra_io::check_runtime_path(
        &PathBuf::from(format!("/proc/self/fd/{}", parent.as_raw_fd())).join(name),
    )?;
    let name = CString::new(name.as_bytes()).map_err(|_| Error::InvalidRoots)?;
    let file = owned(unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    })?;
    fastra_io::check_runtime_file(&file)?;
    Ok(file)
}
fn open_dir(path: &Path) -> Result<File> {
    fastra_io::check_runtime_path(path)?;
    if !path.is_absolute() {
        return Err(Error::InvalidRoots);
    }
    let mut file = owned(unsafe {
        libc::open(
            c"/".as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY,
        )
    })?;
    for part in path.components() {
        match part {
            Component::RootDir => {}
            Component::Normal(name) => file = open_child(&file, name)?,
            _ => return Err(Error::InvalidRoots),
        }
    }
    Ok(file)
}
impl Directory {
    fn validate(&self) -> Result<()> {
        if stamp(&self.handle.metadata()?) != self.stamp
            || stamp(&open_dir(&self.path)?.metadata()?) != self.stamp
        {
            return Err(Error::Stale);
        }
        Ok(())
    }
}
#[derive(Debug)]
pub struct FolderPreview {
    files: Vec<FilePreview>,
    directories: Vec<Directory>,
    skipped: Vec<Skipped>,
    generation: u64,
    matches: usize,
    workflow: Option<WorkflowContext>,
}
impl FolderPreview {
    pub fn workflow_locale(&self) -> Option<&fastra_core::text_operations::TitlecaseLocale> {
        self.workflow.as_ref().and_then(|w| w.locale.as_ref())
    }
    pub fn files(&self) -> &[FilePreview] {
        &self.files
    }
    pub fn skipped(&self) -> &[Skipped] {
        &self.skipped
    }
    pub fn matches(&self) -> usize {
        self.matches
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn changed_paths(
        &self,
        generation: u64,
        approved: &[Vec<usize>],
        cancel: &Cancellation,
    ) -> Result<Vec<PathBuf>> {
        cancel.check()?;
        if generation != self.generation {
            return Err(Error::Stale);
        }
        if approved.len() != self.files.len() {
            return Err(Error::InvalidApproval);
        }
        let mut paths = Vec::new();
        for (file, indices) in self.files.iter().zip(approved) {
            let after = file.after(indices, cancel)?;
            if after != file.preview.source() {
                paths.push(file.path());
            }
        }
        Ok(paths)
    }
    pub fn apply(
        &self,
        generation: u64,
        approved: &[Vec<usize>],
        cancel: &Cancellation,
    ) -> Result<Option<Transaction>> {
        cancel.check()?;
        if generation != self.generation {
            return Err(Error::Stale);
        }
        if approved.len() != self.files.len() {
            return Err(Error::InvalidApproval);
        }
        for dir in &self.directories {
            dir.validate()?;
        }
        if let Some(context) = &self.workflow {
            for file in &self.files {
                file.workflow
                    .as_ref()
                    .ok_or(Error::Stale)?
                    .apply_with_locale(
                        file.preview.source(),
                        0,
                        generation,
                        &context.definition,
                        None,
                        context.locale.as_ref(),
                        cancel,
                    )
                    .map_err(|e| Error::Workflow {
                        path: file.path(),
                        error: e,
                    })?;
            }
        }
        let mut changes = Vec::with_capacity(self.files.len());
        // Auch abgewählte und wirkungslose Treffer bleiben im abschließenden Platten-Preflight.
        for (file, indices) in self.files.iter().zip(approved) {
            changes.push(Change::from_preview(
                file.snapshot.clone(),
                &file.preview,
                0,
                generation,
                indices,
                cancel,
            )?);
        }
        Ok(Transaction::apply(changes, cancel)?)
    }
}
fn writable(path: &Path) -> bool {
    CString::new(path.as_os_str().as_bytes()).is_ok_and(|path| unsafe {
        libc::faccessat(
            libc::AT_FDCWD,
            path.as_ptr(),
            libc::W_OK,
            libc::AT_EACCESS | libc::AT_SYMLINK_NOFOLLOW,
        ) == 0
    })
}
struct Rule {
    path: bool,
    search: PreparedSearch,
}
/// Gemeinsame projektbezogene Pfadfilter für Suche und lokale Analyse.
pub struct Exclusions(Vec<Rule>);
impl Exclusions {
    pub fn new(patterns: &[String], cancel: &Cancellation) -> Result<Self> {
        if patterns.len() > 256 {
            return Err(Error::Limit);
        }
        let mut rules = Vec::new();
        for raw in patterns {
            let raw = raw.trim();
            if raw.is_empty() {
                continue;
            }
            if raw.len() > 4096 {
                return Err(Error::Limit);
            }
            let mut pattern: String = raw.nfc().collect();
            if pattern.starts_with('.') && pattern.len() > 1 && !pattern.contains(['/', '*', '?']) {
                pattern.insert(0, '*');
            }
            let mut regex = String::from("^");
            let mut chars = pattern.chars().peekable();
            while let Some(c) = chars.next() {
                match c {
                    '*' if chars.peek() == Some(&'*') => {
                        chars.next();
                        regex.push_str(".*");
                    }
                    '*' => regex.push_str("[^/]*"),
                    '?' => regex.push_str("[^/]"),
                    c => {
                        if ".+()[]{}^$|\\".contains(c) {
                            regex.push('\\');
                        }
                        regex.push(c);
                    }
                }
            }
            regex.push('$');
            let search = PreparedSearch::new(
                &SearchRequest {
                    pattern: regex,
                    replacement: String::new(),
                    mode: SearchMode::Regex,
                    case_sensitive: true,
                    range: None,
                },
                SearchFlags::default(),
                Limits::default(),
                cancel,
            )?;
            rules.push(Rule {
                path: pattern.contains('/'),
                search,
            });
        }
        Ok(Self(rules))
    }
    pub fn matches(&self, relative: &Path) -> Result<bool> {
        if self.0.is_empty() {
            return Ok(false);
        }
        let value = relative.to_str().ok_or(Error::InvalidRoots)?;
        let value: String = value.nfc().collect();
        for rule in &self.0 {
            if rule.path {
                if !rule.search.preview(&value, 0, 0)?.matches().is_empty() {
                    return Ok(true);
                }
            } else {
                for component in value.split('/') {
                    if !rule.search.preview(component, 0, 0)?.matches().is_empty() {
                        return Ok(true);
                    }
                }
            }
        }
        Ok(false)
    }
}
struct Walker<'a> {
    request: &'a Request,
    selection: selection::Selection,
    search: Option<PreparedSearch>,
    workflow: Option<WorkflowContext>,
    retained: usize,
    source_bytes: usize,
    output_bytes: usize,
    exclude: Exclusions,
    cancel: &'a Cancellation,
    start: Instant,
    result: FolderPreview,
    seen: HashSet<PathBuf>,
    entries: usize,
    bytes: usize,
    captures: usize,
}
impl Walker<'_> {
    fn check(&self) -> Result<()> {
        self.cancel.check()?;
        if self.start.elapsed() > Duration::from_secs(30) {
            return Err(Error::Limit);
        }
        Ok(())
    }
    fn skip(&mut self, path: PathBuf, reason: SkipReason) -> Result<()> {
        if self.workflow.is_some() {
            return Err(Error::WorkflowInput {
                path,
                message: format!("{reason:?}"),
            });
        }
        self.result.skipped.push(Skipped { path, reason });
        Ok(())
    }
    fn file(&mut self, child: PathBuf, size: u64) -> Result<()> {
        self.check()?;
        fastra_io::check_runtime_path(&child)?;
        if !self.seen.insert(child.clone()) {
            if self.workflow.is_some() {
                return Err(Error::WorkflowInput {
                    path: child,
                    message: "DuplicateInput".into(),
                });
            }
            return Ok(());
        }
        if size > 4 * 1024 * 1024 {
            self.skip(child, SkipReason::TooLarge)?;
            return Ok(());
        }
        let snapshot = match Snapshot::read_bounded(&child, 4 * 1024 * 1024, self.cancel) {
            Ok(s) => s,
            Err(fastra_io::Error::UnsupportedMetadata) => {
                self.skip(child, SkipReason::UnsupportedFile)?;
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };
        let decoded = match encoding::decode(snapshot.bytes(), None) {
            Ok(d) => d,
            Err(_) => {
                self.skip(child, SkipReason::Binary)?;
                return Ok(());
            }
        };
        if decoded.text().contains('\0') {
            self.skip(child, SkipReason::Binary)?;
            return Ok(());
        }
        if decoded
            .text()
            .split(['\r', '\n'])
            .any(|line| line.len() > 64 * 1024)
        {
            self.skip(child, SkipReason::LongLine)?;
            return Ok(());
        }
        self.bytes = self
            .bytes
            .checked_add(snapshot.bytes().len() + decoded.text().len())
            .ok_or(Error::Limit)?;
        if self.bytes > 128 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        let (preview, workflow) = if let Some(context) = &self.workflow {
            if self.result.files.len() >= 32 {
                return Err(Error::Limit);
            }
            let flow = fastra_workflow::preview_with_locale(
                &context.definition,
                decoded.text(),
                None,
                0,
                self.result.generation,
                context.locale.as_ref(),
                self.cancel,
            )
            .map_err(|e| Error::Workflow {
                path: child.clone(),
                error: e,
            })?;
            let encoded = decoded.encode(flow.output()).map_err(|e| Error::Encoding {
                path: child.clone(),
                error: e,
            })?;
            if encoded != snapshot.bytes()
                && (!writable(&child) || !child.parent().is_some_and(writable))
            {
                return Err(Error::WorkflowInput {
                    path: child.clone(),
                    message: "NotWritable".into(),
                });
            }
            self.source_bytes = self
                .source_bytes
                .checked_add(snapshot.bytes().len().max(decoded.text().len()))
                .ok_or(Error::Limit)?;
            self.output_bytes = self
                .output_bytes
                .checked_add(encoded.len().max(flow.output().len()))
                .ok_or(Error::Limit)?;
            if self.source_bytes > 16 * 1024 * 1024 || self.output_bytes > 16 * 1024 * 1024 {
                return Err(Error::Limit);
            }
            let mut seen = HashSet::new();
            for step in &flow.steps {
                for text in [&step.before, &step.after] {
                    self.cancel.check()?;
                    if text.contains('\0')
                        || text
                            .split(['\r', '\n', '\u{85}', '\u{2028}', '\u{2029}'])
                            .any(|line| line.len() > 64 * 1024)
                    {
                        return Err(Error::WorkflowInput {
                            path: child.clone(),
                            message: "NUL/long line".into(),
                        });
                    }
                    if seen.insert((text.as_ptr() as usize, text.len())) {
                        self.retained =
                            self.retained.checked_add(text.len()).ok_or(Error::Limit)?;
                    }
                }
            }
            if self.retained > 32 * 1024 * 1024 {
                return Err(Error::Limit);
            }
            let batch = fastra_core::batch::BatchPreview::from_replacements(
                vec![fastra_core::batch::DocumentSnapshot {
                    id: "file".into(),
                    revision: 0,
                    text: decoded.text().into(),
                }],
                vec![flow.output().into()],
                self.result.generation,
                fastra_core::batch::BatchLimits {
                    max_documents: 1,
                    max_source_bytes: 4 * 1024 * 1024,
                    max_preview_bytes: 8 * 1024 * 1024,
                    max_plan_bytes: 4 * 1024 * 1024,
                    max_matches: 1,
                },
                self.cancel,
            )?;
            (batch.documents()[0].preview(), Some(Arc::new(flow)))
        } else {
            (
                Arc::new(self.search.as_ref().unwrap().preview(
                    decoded.text(),
                    0,
                    self.result.generation,
                )?),
                None,
            )
        };
        if self.workflow.is_some() && self.bytes > 32 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        self.result.matches += preview.matches().len();
        self.captures += preview
            .matches()
            .iter()
            .map(|m| m.captures.len())
            .sum::<usize>();
        if self.result.matches > 10_000 || self.captures > 1_000_000 {
            return Err(Error::Limit);
        }
        self.bytes = self
            .bytes
            .checked_add(
                preview
                    .matches()
                    .iter()
                    .map(|m| {
                        m.replacement.len()
                            + m.captures.len()
                                * std::mem::size_of::<Option<fastra_core::Utf16Range>>()
                    })
                    .sum::<usize>(),
            )
            .ok_or(Error::Limit)?;
        if self.bytes > 128 * 1024 * 1024 || self.result.files.len() >= 10_000 {
            return Err(Error::Limit);
        }
        if self.workflow.is_some() && self.bytes > 32 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        self.result.files.push(FilePreview {
            snapshot,
            preview,
            workflow,
        });

        Ok(())
    }
    fn walk(&mut self, root: &Path, path: &Path, handle: File, depth: usize) -> Result<()> {
        self.check()?;
        fastra_io::check_runtime_path(path)?;
        fastra_io::check_runtime_file(&handle)?;
        if depth > 128 || self.result.directories.len() >= 10_000 {
            return Err(Error::Limit);
        }
        let before = stamp(&handle.metadata()?);
        let mut children = Vec::new();
        for child in fs::read_dir(format!("/proc/self/fd/{}", handle.as_raw_fd()))? {
            self.check()?;
            self.entries += 1;
            if self.entries > 100_000 {
                return Err(Error::Limit);
            }
            children.push(child?);
        }
        children.sort_by_key(|entry| entry.file_name());
        for entry in children {
            self.check()?;
            let name = entry.file_name();
            let child = path.join(&name);
            let relative = child.strip_prefix(root).map_err(|_| Error::InvalidRoots)?;
            let kind = entry.file_type()?;
            if !self.selection.visit(relative, kind.is_dir()) {
                continue;
            }
            fastra_io::check_runtime_path(&child)?;
            if relative.to_str().is_none() && !self.exclude.0.is_empty() {
                self.skip(child, SkipReason::NonUnicodePath)?;
                continue;
            }
            if !self.request.include_hidden && name.as_bytes().starts_with(b".") {
                continue;
            }
            if self.exclude.matches(relative)? {
                continue;
            }
            if kind.is_dir() {
                let next = open_child(&handle, &name)?;
                self.walk(root, &child, next, depth + 1)?;
            } else if kind.is_file() {
                if self.request.known_text_only && !is_known_text(&child) {
                    continue;
                }
                self.file(child, entry.metadata()?.len())?;
            } else {
                self.skip(child, SkipReason::LinkOrSpecial)?
            }
        }
        let directory = Directory {
            path: path.to_owned(),
            handle,
            stamp: before,
        };
        directory.validate()?;
        self.result.directories.push(directory);
        Ok(())
    }
}
pub fn preview(request: &Request, generation: u64, cancel: &Cancellation) -> Result<FolderPreview> {
    preview_selected(request, None, generation, cancel)
}
/// Projekt-relative Datei-Sets begrenzen den Lauf vor dem Öffnen der Eingaben.
/// Eine explizit leere oder ungültige Auswahl wird niemals zur Gesamtsuche.
pub fn preview_selected(
    request: &Request,
    paths: Option<&[PathBuf]>,
    generation: u64,
    cancel: &Cancellation,
) -> Result<FolderPreview> {
    let selection = selection::Selection::new(paths, request.roots.len())?;
    if request.roots.is_empty() || request.roots.len() > 64 || request.search.range.is_some() {
        return Err(Error::InvalidRoots);
    }
    let search = PreparedSearch::new(
        &request.search,
        request.flags,
        Limits {
            max_matches: 10_000,
            max_text_bytes: 4 * 1024 * 1024,
            max_output_bytes: 8 * 1024 * 1024,
            ..Limits::default()
        },
        cancel,
    )?;
    preview_inner(
        request,
        generation,
        Some(search),
        None,
        &[],
        selection,
        cancel,
    )
}
/// Rechnet alle Stufen und prüft die Rückkodierung, bevor ein freigabefähiger Plan entsteht.
/// Apply/Undo bleiben beim vorhandenen FolderPreview und der gemeinsamen IO-Transaktion.
pub fn preview_workflow(
    request: &WorkflowRequest,
    generation: u64,
    cancel: &Cancellation,
) -> Result<FolderPreview> {
    if request.roots.len() > 1
        || request.files.len() > 32
        || (request.roots.is_empty() && request.files.is_empty())
    {
        return Err(Error::InvalidRoots);
    }
    let source = Request {
        roots: request.roots.clone(),
        exclusions: request.exclusions.clone(),
        known_text_only: request.known_text_only,
        include_hidden: false,
        flags: SearchFlags::default(),
        search: SearchRequest {
            pattern: String::new(),
            replacement: String::new(),
            mode: SearchMode::Literal,
            case_sensitive: true,
            range: None,
        },
    };
    preview_inner(
        &source,
        generation,
        None,
        Some(WorkflowContext {
            definition: request.definition.clone(),
            locale: request.locale.clone(),
        }),
        &request.files,
        selection::Selection::new(None, source.roots.len())?,
        cancel,
    )
}
fn preview_inner(
    request: &Request,
    generation: u64,
    search: Option<PreparedSearch>,
    workflow: Option<WorkflowContext>,
    files: &[PathBuf],
    selection: selection::Selection,
    cancel: &Cancellation,
) -> Result<FolderPreview> {
    let mut walker = Walker {
        request,
        selection,
        search,
        workflow: workflow.clone(),
        retained: 0,
        source_bytes: 0,
        output_bytes: 0,
        exclude: Exclusions::new(&request.exclusions, cancel)?,
        cancel,
        start: Instant::now(),
        result: FolderPreview {
            files: vec![],
            directories: vec![],
            skipped: vec![],
            generation,
            matches: 0,
            workflow,
        },
        seen: HashSet::new(),
        entries: 0,
        bytes: 0,
        captures: 0,
    };
    let mut roots = Vec::new();
    for root in &request.roots {
        fastra_io::check_runtime_path(root)?;
        let root = fs::canonicalize(root)?;
        if !roots.contains(&root) {
            roots.push(root)
        }
    }
    roots.sort();
    for root in roots {
        walker.walk(&root, &root, open_dir(&root)?, 0)?;
    }
    for path in files {
        walker.check()?;
        fastra_io::check_runtime_path(path)?;
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_file() {
            return Err(Error::WorkflowInput {
                path: path.clone(),
                message: "not a regular file".into(),
            });
        }
        let parent = path.parent().ok_or(Error::InvalidRoots)?;
        let handle = open_dir(parent)?;
        let before = stamp(&handle.metadata()?);
        walker.file(path.clone(), metadata.len())?;
        let directory = Directory {
            path: parent.into(),
            handle,
            stamp: before,
        };
        directory.validate()?;
        walker.result.directories.push(directory);
    }
    for directory in &walker.result.directories {
        directory.validate()?;
    }
    walker.check()?;
    Ok(walker.result)
}

/// Dieselbe bewusste Textendungs-Auswahl wie im Mac-Ordnerfilter.
pub fn is_known_text(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(OsStr::to_str) else {
        return false;
    };
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "txt"
            | "md"
            | "markdown"
            | "rst"
            | "log"
            | "swift"
            | "py"
            | "rb"
            | "js"
            | "ts"
            | "tsx"
            | "jsx"
            | "mjs"
            | "cjs"
            | "java"
            | "kt"
            | "kts"
            | "go"
            | "rs"
            | "c"
            | "cc"
            | "cpp"
            | "h"
            | "hpp"
            | "m"
            | "mm"
            | "cs"
            | "php"
            | "lua"
            | "pl"
            | "r"
            | "scala"
            | "sh"
            | "bash"
            | "zsh"
            | "fish"
            | "ps1"
            | "bat"
            | "cmd"
            | "html"
            | "htm"
            | "xhtml"
            | "xml"
            | "css"
            | "scss"
            | "sass"
            | "less"
            | "vue"
            | "svelte"
            | "json"
            | "jsonl"
            | "yaml"
            | "yml"
            | "toml"
            | "ini"
            | "conf"
            | "env"
            | "csv"
            | "tsv"
            | "tab"
            | "sql"
            | "graphql"
            | "gql"
            | "gitignore"
            | "gitattributes"
            | "dockerignore"
            | "editorconfig"
            | "tex"
            | "bib"
            | "rtf"
            | "adoc"
            | "asciidoc"
    )
}
