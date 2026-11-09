//! Lokaler PMT-Verbraucher. Vorschau und Zustimmung sowie der UI-Thread gehören dem Host.
#[cfg(not(target_os = "linux"))]
compile_error!("fastra-import currently requires the verified Linux no-replace path");
mod catalog;
mod progress;
mod protocol;
pub use catalog::ToolCatalog;
pub use progress::{Counts, Phase, Progress, ProgressParser, Unit};
mod tree;
pub use fastra_process::{Cancellation, Output, Policy};
pub use protocol::{
    utf8_to_utf16, Catalog, Conversion, Document, Format, OutputFile, OutputRange, SourceMapping,
    Utf16Span,
};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};
pub use tree::FileRecord;
use tree::{EntryRecord, Manifest};

#[derive(Debug)]
pub enum Error {
    Process(fastra_process::Error),
    Tool {
        message: Option<String>,
        output: Output,
    },
    Protocol(String),
    UnsafeTree(&'static str),
    Limit(&'static str),
    Io(String),
    StaleOwner,
    StalePrepared,
    Cancelled,
    InvalidPath(&'static str),
    CollisionLimit,
    PublishedButNotDurable {
        publication: Box<Publication>,
        message: String,
    },
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
impl From<fastra_process::Error> for Error {
    fn from(error: fastra_process::Error) -> Self {
        Self::Process(error)
    }
}
fn io(error: std::io::Error) -> Error {
    Error::Io(error.to_string())
}
fn check_cancel(cancel: &Cancellation) -> Result<(), Error> {
    if cancel.is_cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_json_bytes: usize,
    pub max_entries: usize,
    pub max_depth: usize,
    pub max_path_bytes: usize,
    pub max_file_bytes: u64,
    pub max_markdown_bytes: u64,
    pub max_total_bytes: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            max_json_bytes: 4 * 1024 * 1024,
            max_entries: 10_000,
            max_depth: 32,
            max_path_bytes: 4096,
            max_file_bytes: 128 * 1024 * 1024,
            max_markdown_bytes: 32 * 1024 * 1024,
            max_total_bytes: 512 * 1024 * 1024,
        }
    }
}
impl Limits {
    fn check(self) -> Result<(), Error> {
        let ceiling = Self::default();
        if self.max_json_bytes == 0
            || self.max_json_bytes > ceiling.max_json_bytes
            || self.max_entries == 0
            || self.max_entries > ceiling.max_entries
            || self.max_depth > ceiling.max_depth
            || self.max_path_bytes == 0
            || self.max_path_bytes > ceiling.max_path_bytes
            || self.max_file_bytes > ceiling.max_file_bytes
            || self.max_markdown_bytes > ceiling.max_markdown_bytes
            || self.max_total_bytes > ceiling.max_total_bytes
        {
            return Err(Error::Limit("invalid import limits"));
        }
        Ok(())
    }
}
/// Der Host liest diesen Zustand unmittelbar vor Adoption auf seiner Besitz-Queue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerBinding {
    pub document_id: String,
    pub document_revision: u64,
    pub project_id: Option<String>,
    pub generation: u64,
}
#[derive(Debug, Clone)]
pub struct DocumentPreview {
    pub source_index: u64,
    pub title: String,
    pub markdown: PathBuf,
    pub assets: Vec<PathBuf>,
    pub metadata: serde_json::Value,
}
#[derive(Debug, Clone)]
pub struct ImportPreview {
    pub owner: OwnerBinding,
    pub entry: PathBuf,
    pub files: BTreeMap<PathBuf, FileRecord>,
    pub documents: Vec<DocumentPreview>,
    /// Vollständige, aus dem versiegelten Baum gelesene Texte der Vorschau.
    pub markdown_text: BTreeMap<PathBuf, String>,
    pub assets: Vec<PathBuf>,
    pub report: Option<PathBuf>,
    /// Einschließlich unbekannter Felder und Verlustdiagnosen, nie still entfernt.
    pub response: Conversion,
    pub process_output: Output,
}
#[derive(Debug, Clone)]
pub struct Publication {
    pub directory: PathBuf,
    pub markdown: PathBuf,
    pub owner: OwnerBinding,
    /// Diagnosen und relative Dokumentpfade bleiben nach Ende des Jobs erhalten.
    pub preview: ImportPreview,
}
struct OwnedStaging {
    temporary: Option<tempfile::TempDir>,
    identity: (u64, u64),
}
impl OwnedStaging {
    fn new(parent: &Path) -> Result<Self, Error> {
        let temporary = tempfile::Builder::new()
            .prefix(".fastra-import-")
            .tempdir_in(parent)
            .map_err(io)?;
        let identity = tree::identity(&fs::symlink_metadata(temporary.path()).map_err(io)?);
        Ok(Self {
            temporary: Some(temporary),
            identity,
        })
    }
    fn path(&self) -> &Path {
        self.temporary.as_ref().expect("owned staging").path()
    }
    fn valid(&self) -> bool {
        fs::symlink_metadata(self.path())
            .is_ok_and(|m| m.is_dir() && tree::identity(&m) == self.identity)
    }
}
impl Drop for OwnedStaging {
    fn drop(&mut self) {
        if !self.valid() {
            // Ein untergeschobener Ordner darf niemals durch TempDir entfernt werden.
            if let Some(directory) = self.temporary.take() {
                let _ = directory.keep();
            }
        }
    }
}
pub struct PreparedImport {
    staging: OwnedStaging,
    staging_handle: fs::File,
    destination_parent: PathBuf,
    destination_handle: fs::File,
    destination_identity: (u64, u64),
    prepared_identity: (u64, u64),
    preview: ImportPreview,
    manifest: Manifest,
    limits: Limits,
}
#[derive(Debug, Clone)]
pub struct Importer {
    executable: PathBuf,
    #[cfg(test)]
    argument_prefix: Vec<OsString>,
}
impl Importer {
    pub fn new(executable: PathBuf) -> Result<Self, Error> {
        if !executable.is_absolute() || executable.to_str().is_none() {
            return Err(Error::InvalidPath("CLI path must be absolute UTF-8"));
        }
        Ok(Self {
            executable,
            #[cfg(test)]
            argument_prefix: Vec::new(),
        })
    }
    fn run(
        &self,
        working: &Path,
        args: &[OsString],
        mut policy: Policy,
        limits: Limits,
        cancel: &Cancellation,
        observer: Option<fastra_process::StderrObserver<'_>>,
    ) -> Result<Output, Error> {
        limits.check()?;
        policy.stdout_bytes = policy.stdout_bytes.min(limits.max_json_bytes);
        let mut arguments = Vec::new();
        #[cfg(test)]
        arguments.extend_from_slice(&self.argument_prefix);
        arguments.extend_from_slice(args);
        let environment = fastra_process::Environment {
            remove_prefixes: vec!["GIT_".into()],
            set: vec![],
        };
        let mut ignore = |_: &[u8]| {};
        let output = fastra_process::run_with_stderr(
            &self.executable,
            working,
            &arguments,
            policy,
            cancel,
            &environment,
            fastra_process::ParentLoss::Terminate,
            observer.unwrap_or(&mut ignore),
        )?;
        if !output.success() {
            let message = serde_json::from_slice::<serde_json::Value>(&output.stdout)
                .ok()
                .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_owned));
            return Err(Error::Tool { message, output });
        }
        Ok(output)
    }
    pub fn catalog(
        &self,
        policy: Policy,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<(Catalog, Output), Error> {
        let output = self.run(
            Path::new("/"),
            &["--formats".into(), "--json".into()],
            policy,
            limits,
            cancel,
            None,
        )?;
        Ok((Catalog::decode(&output.stdout, limits)?, output))
    }
    pub fn prepare(
        &self,
        source: &Path,
        destination_parent: &Path,
        owner: OwnerBinding,
        policy: Policy,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<PreparedImport, Error> {
        self.prepare_observed(
            source,
            destination_parent,
            owner,
            policy,
            limits,
            cancel,
            false,
            &mut |_| {},
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub fn prepare_observed(
        &self,
        source: &Path,
        destination_parent: &Path,
        owner: OwnerBinding,
        policy: Policy,
        limits: Limits,
        cancel: &Cancellation,
        progress: bool,
        observer: &mut dyn FnMut(Progress),
    ) -> Result<PreparedImport, Error> {
        limits.check()?;
        check_cancel(cancel)?;
        fastra_io::check_runtime_path(source).map_err(io)?;
        fastra_io::check_runtime_path(destination_parent).map_err(io)?;
        // Vor canonicalize prüfen: Der JSON-Vertrag erlaubt keine stille Byte-Ersetzung.
        if source.to_str().is_none() || destination_parent.to_str().is_none() {
            return Err(Error::InvalidPath("non-UTF-8 import path"));
        }
        let source = fs::canonicalize(source).map_err(io)?;
        let destination_parent = fs::canonicalize(destination_parent).map_err(io)?;
        if source.to_str().is_none() || destination_parent.to_str().is_none() {
            return Err(Error::InvalidPath("non-UTF-8 canonical path"));
        }
        let destination_handle = tree::directory(&destination_parent)?;
        fastra_io::check_runtime_file(&destination_handle).map_err(io)?;
        let destination_identity = tree::identity(&destination_handle.metadata().map_err(io)?);
        let staging = OwnedStaging::new(&destination_parent)?;
        let staging_handle = tree::directory(staging.path())?;
        let output_path = staging.path().join("out");
        let mut args = vec![
            "--json".into(),
            "--output".into(),
            output_path.as_os_str().to_owned(),
            "--".into(),
            source.as_os_str().to_owned(),
        ];
        if progress {
            args.insert(0, "--progress".into());
        }
        let mut parser = ProgressParser::new(
            source
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or(""),
        );
        let mut observe = |bytes: &[u8]| {
            if let Some(progress) = parser.consume(bytes) {
                observer(progress);
            }
        };
        let process_output = self.run(
            staging.path(),
            &args,
            policy,
            limits,
            cancel,
            Some(&mut observe),
        )?;
        check_cancel(cancel)?;
        let root: serde_json::Value = serde_json::from_slice(&process_output.stdout)
            .map_err(|e| Error::Protocol(e.to_string()))?;
        if root.get("ok").and_then(|v| v.as_bool()) != Some(true) {
            return Err(Error::Tool {
                message: root
                    .get("error")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned),
                output: process_output,
            });
        }
        let response = Conversion::decode(&process_output.stdout, limits)?;
        if !staging.valid() {
            return Err(Error::UnsafeTree("staging root replaced by producer"));
        }
        // Erst lstat/openat auf die unvertrauenswürdige Wurzel, keine Pfadauflösung davor.
        let output = tree::output_directory(&staging_handle, "out")?;
        let prepared_path = staging.path().join("prepared");
        let manifest = tree::sealed_copy(&output, &prepared_path, limits, cancel)?;
        let preview = validate_response(
            response,
            &source,
            &output_path,
            &prepared_path,
            &manifest,
            owner,
            process_output,
            limits,
            cancel,
        )?;
        let prepared_identity =
            tree::identity(&tree::directory(&prepared_path)?.metadata().map_err(io)?);
        staging_handle.sync_all().map_err(io)?;
        Ok(PreparedImport {
            staging,
            staging_handle,
            destination_parent,
            destination_handle,
            destination_identity,
            prepared_identity,
            preview,
            manifest,
            limits,
        })
    }
}
fn reported_file(path: &str, output: &Path, manifest: &Manifest) -> Result<PathBuf, Error> {
    if path.as_bytes().contains(&0) {
        return Err(Error::UnsafeTree("NUL in reported path"));
    }
    let relative = Path::new(path)
        .strip_prefix(output)
        .map_err(|_| Error::UnsafeTree("reported file outside own output"))?;
    tree::safe_relative(relative)?;
    if !matches!(manifest.get(relative), Some(EntryRecord::File(_))) {
        return Err(Error::UnsafeTree(
            "reported file missing from complete validated tree",
        ));
    }
    Ok(relative.to_owned())
}
#[allow(clippy::too_many_arguments)]
fn validate_response(
    response: Conversion,
    source: &Path,
    output: &Path,
    prepared: &Path,
    manifest: &Manifest,
    owner: OwnerBinding,
    process_output: Output,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<ImportPreview, Error> {
    if let Some(reported) = &response.output_directory {
        if Path::new(reported) != output {
            return Err(Error::UnsafeTree(
                "producer reported foreign output directory",
            ));
        }
    }
    if let Some(reported) = &response.input {
        if Path::new(reported) != source {
            return Err(Error::UnsafeTree("producer reported different source"));
        }
    }
    let entry = reported_file(&response.markdown_file, output, manifest)?;
    let assets = response
        .assets
        .as_deref()
        .unwrap_or_default()
        .iter()
        .map(|p| reported_file(p, output, manifest))
        .collect::<Result<Vec<_>, _>>()?;
    let report = response
        .report_file
        .as_ref()
        .map(|p| reported_file(p, output, manifest))
        .transpose()?;
    let mut documents = Vec::new();
    let mut indexes = std::collections::HashSet::new();
    for document in response.documents.as_deref().unwrap_or_default() {
        check_cancel(cancel)?;
        if document.source_index == 0 || !indexes.insert(document.source_index) {
            return Err(Error::Protocol("invalid collection document index".into()));
        }
        documents.push(DocumentPreview {
            source_index: document.source_index,
            title: document.title.clone(),
            markdown: reported_file(&document.markdown_file, output, manifest)?,
            assets: document
                .assets
                .iter()
                .map(|p| reported_file(p, output, manifest))
                .collect::<Result<Vec<_>, _>>()?,
            metadata: document.metadata.clone(),
        });
    }
    for file in response.output_files.as_deref().unwrap_or_default() {
        check_cancel(cancel)?;
        let path = Path::new(&file.path);
        tree::safe_relative(path)?;
        match manifest.get(path) {
            Some(EntryRecord::File(record))
                if record.bytes == file.byte_count && record.sha256 == file.sha256 => {}
            _ => {
                return Err(Error::Protocol(
                    "output manifest hash or byte count differs".into(),
                ))
            }
        }
    }
    let prepared_handle = tree::directory(prepared)?;
    // Text wird einmal pro betroffener Datei begrenzt gelesen, nicht pro Mapping.
    let mut text_paths = std::collections::BTreeMap::<PathBuf, Vec<&SourceMapping>>::new();
    text_paths.entry(entry.clone()).or_default();
    for document in &documents {
        text_paths.entry(document.markdown.clone()).or_default();
    }
    for mapping in response.source_mappings.as_deref().unwrap_or_default() {
        let path = Path::new(&mapping.output.file);
        tree::safe_relative(path)?;
        if !matches!(manifest.get(path), Some(EntryRecord::File(_))) {
            return Err(Error::Protocol("mapping file missing".into()));
        }
        text_paths.entry(path.to_owned()).or_default().push(mapping);
    }
    let mut markdown_text = BTreeMap::new();
    let mut text_bytes = 0u64;
    for (path, mappings) in text_paths {
        check_cancel(cancel)?;
        let text = tree::read_text(&prepared_handle, &path, limits.max_markdown_bytes, cancel)?;
        text_bytes = text_bytes
            .checked_add(text.len() as u64)
            .ok_or(Error::Limit("preview text bytes"))?;
        if text_bytes > limits.max_markdown_bytes {
            return Err(Error::Limit("preview text bytes"));
        }
        for mapping in mappings {
            check_cancel(cancel)?;
            utf8_to_utf16(
                &text,
                mapping.output.utf8_offset,
                mapping.output.utf8_length,
            )?;
        }
        markdown_text.insert(path, text);
    }
    let files = manifest
        .iter()
        .filter_map(|(path, entry)| {
            if let EntryRecord::File(file) = entry {
                Some((path.clone(), file.clone()))
            } else {
                None
            }
        })
        .collect();
    Ok(ImportPreview {
        owner,
        entry,
        files,
        documents,
        markdown_text,
        assets,
        report,
        response,
        process_output,
    })
}
impl PreparedImport {
    pub fn preview(&self) -> &ImportPreview {
        &self.preview
    }
    pub fn adopt(
        self,
        current_owner: &OwnerBinding,
        stem: &str,
        cancel: &Cancellation,
    ) -> Result<Publication, Error> {
        if current_owner != &self.preview.owner {
            return Err(Error::StaleOwner);
        }
        check_cancel(cancel)?;
        if stem.is_empty()
            || stem == "."
            || stem == ".."
            || stem.as_bytes().contains(&0)
            || stem.contains('/')
            || stem.len() > 200
        {
            return Err(Error::InvalidPath(
                "adoption stem must be one bounded component",
            ));
        }
        if !self.staging.valid()
            || tree::identity(
                &tree::directory(&self.destination_parent)?
                    .metadata()
                    .map_err(io)?,
            ) != self.destination_identity
        {
            return Err(Error::StalePrepared);
        }
        let prepared = tree::output_directory(&self.staging_handle, "prepared")?;
        if tree::identity(&prepared.metadata().map_err(io)?) != self.prepared_identity
            || tree::verify_tree(&prepared, self.limits, cancel)? != self.manifest
        {
            return Err(Error::StalePrepared);
        }
        for attempt in 1..=1000 {
            check_cancel(cancel)?;
            fastra_io::check_runtime_file(&self.destination_handle).map_err(io)?;
            let name = if attempt == 1 {
                stem.to_owned()
            } else {
                format!("{stem}-{attempt}")
            };
            fastra_io::check_runtime_path(&self.destination_parent.join(&name)).map_err(io)?;
            if tree::rename_no_replace(
                &self.staging_handle,
                "prepared",
                &self.destination_handle,
                &name,
            )? {
                let directory = self.destination_parent.join(&name);
                let publication = Publication {
                    markdown: directory.join(&self.preview.entry),
                    directory,
                    owner: self.preview.owner.clone(),
                    preview: self.preview.clone(),
                };
                // Nach Rename muss ein Fehler den bereits veröffentlichten Ort erhalten.
                if let Err(error) = self
                    .destination_handle
                    .sync_all()
                    .and_then(|()| self.staging_handle.sync_all())
                {
                    return Err(Error::PublishedButNotDurable {
                        publication: Box::new(publication),
                        message: error.to_string(),
                    });
                }
                return Ok(publication);
            }
        }
        Err(Error::CollisionLimit)
    }
}

#[cfg(test)]
mod tests;
