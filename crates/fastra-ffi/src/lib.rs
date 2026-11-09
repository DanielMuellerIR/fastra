//! Kleine synchrone Sprachgrenze. Hosts führen Suchen außerhalb ihres UI-Threads aus.
use fastra_core as core;
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    sync::Arc,
};

#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum SearchError {
    Regex { code: i32, offset: i32 },
    Engine { code: i32 },
    Cancelled,
    Limit,
    InvalidRange,
    Stale,
    InvalidApproval,
    Internal,
}
impl std::fmt::Display for SearchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for SearchError {}
impl From<core::Error> for SearchError {
    fn from(error: core::Error) -> Self {
        match error {
            core::Error::Regex { code, offset } => Self::Regex { code, offset },
            core::Error::Engine(code) => Self::Engine { code },
            core::Error::Cancelled => Self::Cancelled,
            core::Error::Limit => Self::Limit,
            core::Error::InvalidRange => Self::InvalidRange,
            core::Error::Stale => Self::Stale,
            core::Error::InvalidApproval => Self::InvalidApproval,
        }
    }
}
// Jeder exportierte Aufruf ist werfend: Auch unerwartete Rust-Panics bleiben abfangbar.
fn guarded<T>(body: impl FnOnce() -> Result<T, SearchError>) -> Result<T, SearchError> {
    catch_unwind(AssertUnwindSafe(body)).map_err(|_| SearchError::Internal)?
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Utf16Range {
    pub location: u64,
    pub length: u64,
}
impl Utf16Range {
    fn into_core(self) -> Result<core::Utf16Range, SearchError> {
        Ok(core::Utf16Range {
            location: usize::try_from(self.location).map_err(|_| SearchError::InvalidRange)?,
            length: usize::try_from(self.length).map_err(|_| SearchError::InvalidRange)?,
        })
    }
}
impl From<core::Utf16Range> for Utf16Range {
    fn from(value: core::Utf16Range) -> Self {
        Self {
            location: value.location as u64,
            length: value.length as u64,
        }
    }
}
#[derive(Clone, Copy, uniffi::Enum)]
pub enum SearchMode {
    Literal,
    Wildcard,
    Regex,
}
#[derive(uniffi::Record)]
pub struct SearchRequest {
    pub pattern: String,
    pub replacement: String,
    pub mode: SearchMode,
    pub case_sensitive: bool,
    pub range: Option<Utf16Range>,
}
#[derive(Clone, Copy, uniffi::Record)]
pub struct SearchLimits {
    pub max_matches: u32,
    pub max_text_bytes: u32,
    pub max_output_bytes: u32,
    pub regex_time_ms: u32,
    pub regex_stack_bytes: u32,
}
impl SearchLimits {
    fn into_core(self) -> Result<core::Limits, SearchError> {
        let defaults = core::Limits::default();
        // Hosts dürfen Schutzgrenzen reduzieren, aber nicht unbegrenzt abschalten.
        if self.max_matches == 0
            || self.max_matches as usize > defaults.max_matches
            || self.max_text_bytes == 0
            || self.max_text_bytes as usize > defaults.max_text_bytes
            || self.max_output_bytes == 0
            || self.max_output_bytes as usize > defaults.max_output_bytes
            || self.regex_time_ms == 0
            || self.regex_time_ms > defaults.regex_time_ms as u32
            || self.regex_stack_bytes == 0
            || self.regex_stack_bytes > defaults.regex_stack_bytes as u32
        {
            return Err(SearchError::Limit);
        }
        Ok(core::Limits {
            max_matches: self.max_matches as usize,
            max_text_bytes: self.max_text_bytes as usize,
            max_output_bytes: self.max_output_bytes as usize,
            regex_time_ms: self.regex_time_ms as i32,
            regex_stack_bytes: self.regex_stack_bytes as i32,
        })
    }
}
#[uniffi::export]
pub fn default_search_limits() -> Result<SearchLimits, SearchError> {
    guarded(|| {
        let limits = core::Limits::default();
        Ok(SearchLimits {
            max_matches: limits.max_matches as u32,
            max_text_bytes: limits.max_text_bytes as u32,
            max_output_bytes: limits.max_output_bytes as u32,
            regex_time_ms: limits.regex_time_ms as u32,
            regex_stack_bytes: limits.regex_stack_bytes as u32,
        })
    })
}
#[derive(uniffi::Record)]
pub struct SearchMatch {
    pub range: Utf16Range,
    pub captures: Vec<Option<Utf16Range>>,
    pub replacement: String,
}
#[derive(uniffi::Record)]
pub struct PreviewSnapshot {
    pub source: String,
    pub revision: u64,
    pub generation: u64,
    pub matches: Vec<SearchMatch>,
}
#[derive(uniffi::Object, Default)]
pub struct Cancellation {
    inner: core::Cancellation,
}
#[uniffi::export]
impl Cancellation {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, SearchError> {
        guarded(|| Ok(Arc::new(Self::default())))
    }
    pub fn cancel(&self) -> Result<(), SearchError> {
        guarded(|| {
            self.inner.cancel();
            Ok(())
        })
    }
}
#[derive(uniffi::Object)]
pub struct Preview {
    inner: core::Preview,
}
#[uniffi::export]
impl Preview {
    pub fn snapshot(&self) -> Result<PreviewSnapshot, SearchError> {
        guarded(|| {
            Ok(PreviewSnapshot {
                source: self.inner.source().to_owned(),
                revision: self.inner.revision(),
                generation: self.inner.generation(),
                matches: self
                    .inner
                    .matches()
                    .iter()
                    .map(|hit| SearchMatch {
                        range: hit.range.into(),
                        captures: hit.captures.iter().map(|r| r.map(Into::into)).collect(),
                        replacement: hit.replacement.clone(),
                    })
                    .collect(),
            })
        })
    }
    pub fn apply(
        &self,
        current: String,
        revision: u64,
        generation: u64,
        approved: Vec<u64>,
        cancellation: Arc<Cancellation>,
    ) -> Result<String, SearchError> {
        guarded(|| {
            let approved = approved
                .into_iter()
                .map(|index| usize::try_from(index).map_err(|_| SearchError::InvalidApproval))
                .collect::<Result<Vec<_>, _>>()?;
            self.inner
                .apply(
                    &current,
                    revision,
                    generation,
                    &approved,
                    &cancellation.inner,
                )
                .map_err(Into::into)
        })
    }
}
#[uniffi::export]
pub fn create_preview(
    text: String,
    revision: u64,
    generation: u64,
    request: SearchRequest,
    limits: SearchLimits,
    cancellation: Arc<Cancellation>,
) -> Result<Arc<Preview>, SearchError> {
    guarded(|| {
        let request = core::SearchRequest {
            pattern: request.pattern,
            replacement: request.replacement,
            mode: match request.mode {
                SearchMode::Literal => core::SearchMode::Literal,
                SearchMode::Wildcard => core::SearchMode::Wildcard,
                SearchMode::Regex => core::SearchMode::Regex,
            },
            case_sensitive: request.case_sensitive,
            range: request.range.map(Utf16Range::into_core).transpose()?,
        };
        let inner = core::preview(
            &text,
            revision,
            generation,
            &request,
            limits.into_core()?,
            &cancellation.inner,
        )?;
        Ok(Arc::new(Preview { inner }))
    })
}
uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn panic_is_a_controlled_error() {
        assert_eq!(
            guarded(|| -> Result<(), SearchError> { panic!("test") }),
            Err(SearchError::Internal)
        );
    }
    #[test]
    fn immutable_preview_rejects_stale_and_invalid_approval() {
        let cancel = Cancellation::new().unwrap();
        let preview = create_preview(
            "😀 aa".into(),
            4,
            8,
            SearchRequest {
                pattern: "a".into(),
                replacement: "b".into(),
                mode: SearchMode::Literal,
                case_sensitive: true,
                range: None,
            },
            default_search_limits().unwrap(),
            cancel.clone(),
        )
        .unwrap();
        let snapshot = preview.snapshot().unwrap();
        assert_eq!(
            snapshot.matches[0].range,
            Utf16Range {
                location: 3,
                length: 1
            }
        );
        assert_eq!(
            preview
                .apply(snapshot.source.clone(), 4, 8, vec![0, 1], cancel.clone())
                .unwrap(),
            "😀 bb"
        );
        for (text, revision, generation) in [("😀 ab", 4, 8), ("😀 aa", 5, 8), ("😀 aa", 4, 9)]
        {
            assert_eq!(
                preview.apply(text.into(), revision, generation, vec![], cancel.clone()),
                Err(SearchError::Stale)
            );
        }
        assert_eq!(
            preview.apply(snapshot.source.clone(), 4, 8, vec![1, 0], cancel.clone()),
            Err(SearchError::InvalidApproval)
        );
        cancel.cancel().unwrap();
        assert_eq!(
            preview.apply(snapshot.source, 4, 8, vec![], cancel),
            Err(SearchError::Cancelled)
        );
    }
    #[test]
    fn unlimited_regex_is_rejected() {
        let mut limits = default_search_limits().unwrap();
        limits.regex_time_ms = 0;
        assert!(matches!(limits.into_core(), Err(SearchError::Limit)));
    }
}
