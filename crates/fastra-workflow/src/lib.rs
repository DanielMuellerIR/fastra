//! Gespeicherte Definitionen und begrenzte Vorschauen; keine Dokumentdateien schreiben.
mod engine;
mod model;
pub mod patterns;
pub mod comparison_preferences;
pub mod recent_projects;
pub mod search_history;
pub mod search_locations;
mod snippet;
pub mod store;
mod store_file;
mod unicode;
pub use engine::{preview, preview_with_locale, Preview, StepPreview};
pub use model::{
    new_id, Definition, Snippet, SnippetArchive, Step, Workflow, WorkflowArchive, MAX_ARCHIVE_BYTES,
};
pub use snippet::Template;

#[derive(Debug)]
pub enum Error {
    Invalid(String),
    Unsupported(Vec<String>),
    Limit,
    Stale,
    Missing(String),
    Core(fastra_core::Error),
    Io(std::io::Error),
    Json(serde_json::Error),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
impl From<fastra_core::Error> for Error {
    fn from(e: fastra_core::Error) -> Self {
        Self::Core(e)
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e)
    }
}
