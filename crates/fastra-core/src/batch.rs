//! Mehrdokumentpläne rechnen vollständig vor der ersten Editoränderung.
use crate::{Cancellation, Error, Limits, PreparedSearch, Preview, SearchFlags, SearchRequest};
use std::{collections::HashSet, sync::Arc};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentSnapshot {
    pub id: String,
    pub revision: u64,
    pub text: String,
}
#[derive(Debug, Clone, Copy)]
pub struct BatchLimits {
    pub max_documents: usize,
    pub max_source_bytes: usize,
    pub max_preview_bytes: usize,
    pub max_plan_bytes: usize,
    pub max_matches: usize,
}
impl Default for BatchLimits {
    fn default() -> Self {
        Self {
            max_documents: 128,
            max_source_bytes: 64 * 1024 * 1024,
            max_preview_bytes: 128 * 1024 * 1024,
            max_plan_bytes: 128 * 1024 * 1024,
            max_matches: 10_000,
        }
    }
}
#[derive(Debug)]
pub struct DocumentPreview {
    id: String,
    preview: Arc<Preview>,
}
impl DocumentPreview {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn preview(&self) -> Arc<Preview> {
        self.preview.clone()
    }
}
#[derive(Debug)]
pub struct BatchPreview {
    documents: Vec<DocumentPreview>,
    generation: u64,
    limits: BatchLimits,
}
#[derive(Debug)]
pub struct BatchPlan {
    before: Arc<BatchPreview>,
    outputs: Vec<String>,
}
#[derive(Debug)]
pub struct Restoration {
    original: Arc<BatchPreview>,
    expected: Vec<DocumentSnapshot>,
}
fn identities(documents: &[DocumentSnapshot], limits: BatchLimits) -> Result<(), Error> {
    if documents.len() > limits.max_documents {
        return Err(Error::Limit);
    }
    let mut ids = HashSet::new();
    let mut bytes = 0usize;
    for doc in documents {
        if doc.id.is_empty() || doc.id.len() > 4096 || !ids.insert(&doc.id) {
            return Err(Error::Stale);
        }
        bytes = bytes.checked_add(doc.text.len()).ok_or(Error::Limit)?;
        if bytes > limits.max_source_bytes {
            return Err(Error::Limit);
        }
    }
    Ok(())
}
fn checked_limits(limits: BatchLimits) -> Result<(), Error> {
    let ceiling = BatchLimits::default();
    if limits.max_documents > ceiling.max_documents
        || limits.max_source_bytes > ceiling.max_source_bytes
        || limits.max_preview_bytes > ceiling.max_preview_bytes
        || limits.max_plan_bytes > ceiling.max_plan_bytes
        || limits.max_matches > ceiling.max_matches
    {
        return Err(Error::Limit);
    }
    Ok(())
}
impl BatchPreview {
    /// Vollständige, bereits berechnete Ausgaben; ein Freigabepunkt je Dokument.
    /// Auch wirkungslose oder nicht freigegebene Dokumente bleiben bis Undo gebunden.
    pub fn from_replacements(
        documents: Vec<DocumentSnapshot>,
        outputs: Vec<String>,
        generation: u64,
        limits: BatchLimits,
        cancel: &Cancellation,
    ) -> Result<Arc<Self>, Error> {
        checked_limits(limits)?;
        cancel.check()?;
        identities(&documents, limits)?;
        if documents.len() != outputs.len() {
            return Err(Error::InvalidApproval);
        }
        if documents.len() > limits.max_matches {
            return Err(Error::Limit);
        }
        let mut retained = 0usize;
        let mut total_outputs = 0usize;
        let mut result = Vec::with_capacity(documents.len());
        for (document, output) in documents.into_iter().zip(outputs) {
            cancel.check()?;
            retained = retained
                .checked_add(document.text.len())
                .and_then(|n| n.checked_add(output.len()))
                .ok_or(Error::Limit)?;
            total_outputs = total_outputs
                .checked_add(output.len())
                .ok_or(Error::Limit)?;
            if retained > limits.max_preview_bytes || total_outputs > limits.max_plan_bytes {
                return Err(Error::Limit);
            }
            let length = document.text.encode_utf16().count();
            result.push(DocumentPreview {
                id: document.id,
                preview: Arc::new(Preview {
                    source: document.text,
                    revision: document.revision,
                    generation,
                    matches: vec![crate::Match {
                        range: crate::Utf16Range {
                            location: 0,
                            length,
                        },
                        captures: Vec::new(),
                        replacement: output,
                    }],
                    max_output_bytes: limits.max_plan_bytes,
                }),
            });
        }
        cancel.check()?;
        Ok(Arc::new(Self {
            documents: result,
            generation,
            limits,
        }))
    }
    pub fn create(
        documents: Vec<DocumentSnapshot>,
        generation: u64,
        request: &SearchRequest,
        flags: SearchFlags,
        limits: BatchLimits,
        cancel: &Cancellation,
    ) -> Result<Arc<Self>, Error> {
        checked_limits(limits)?;
        if request.range.is_some() {
            return Err(Error::InvalidRange);
        }
        cancel.check()?;
        identities(&documents, limits)?;
        let search = PreparedSearch::new(
            request,
            flags,
            Limits {
                max_text_bytes: 4 * 1024 * 1024,
                max_output_bytes: 8 * 1024 * 1024,
                max_matches: limits.max_matches,
                ..Limits::default()
            },
            cancel,
        )?;
        let mut result = Vec::with_capacity(documents.len());
        let mut bytes = 0usize;
        let mut matches = 0usize;
        let mut captures = 0usize;
        for document in documents {
            cancel.check()?;
            let preview = search.preview(&document.text, document.revision, generation)?;
            matches = matches
                .checked_add(preview.matches().len())
                .ok_or(Error::Limit)?;
            bytes = bytes
                .checked_add(preview.source().len())
                .ok_or(Error::Limit)?;
            for hit in preview.matches() {
                captures = captures
                    .checked_add(hit.captures.len())
                    .ok_or(Error::Limit)?;
                bytes = bytes
                    .checked_add(hit.replacement.len())
                    .and_then(|n| {
                        n.checked_add(
                            hit.captures.len() * std::mem::size_of::<Option<crate::Utf16Range>>(),
                        )
                    })
                    .ok_or(Error::Limit)?;
            }
            if bytes > limits.max_preview_bytes
                || matches > limits.max_matches
                || captures > 1_000_000
            {
                return Err(Error::Limit);
            }
            result.push(DocumentPreview {
                id: document.id,
                preview: Arc::new(preview),
            });
        }
        Ok(Arc::new(Self {
            documents: result,
            generation,
            limits,
        }))
    }
    pub fn documents(&self) -> &[DocumentPreview] {
        &self.documents
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn validate(
        &self,
        current: &[DocumentSnapshot],
        generation: u64,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        cancel.check()?;
        if generation != self.generation || current.len() != self.documents.len() {
            return Err(Error::Stale);
        }
        for (expected, actual) in self.documents.iter().zip(current) {
            cancel.check()?;
            if expected.id != actual.id
                || expected.preview.revision() != actual.revision
                || expected.preview.source() != actual.text
            {
                return Err(Error::Stale);
            }
        }
        Ok(())
    }
    pub fn plan(
        self: &Arc<Self>,
        current: &[DocumentSnapshot],
        generation: u64,
        approvals: &[Vec<usize>],
        cancel: &Cancellation,
    ) -> Result<BatchPlan, Error> {
        self.validate(current, generation, cancel)?;
        if approvals.len() != self.documents.len() {
            return Err(Error::InvalidApproval);
        }
        let mut outputs = Vec::with_capacity(current.len());
        let mut bytes = 0usize;
        for ((doc, actual), approved) in self.documents.iter().zip(current).zip(approvals) {
            let text =
                doc.preview
                    .apply(&actual.text, actual.revision, generation, approved, cancel)?;
            bytes = bytes.checked_add(text.len()).ok_or(Error::Limit)?;
            if bytes > self.limits.max_plan_bytes {
                return Err(Error::Limit);
            }
            outputs.push(text);
        }
        cancel.check()?;
        Ok(BatchPlan {
            before: self.clone(),
            outputs,
        })
    }
}
impl BatchPlan {
    pub fn outputs(&self) -> &[String] {
        &self.outputs
    }
    pub fn validate(
        &self,
        current: &[DocumentSnapshot],
        generation: u64,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        self.before.validate(current, generation, cancel)
    }
    pub fn bind_restoration(
        &self,
        after: Vec<DocumentSnapshot>,
        cancel: &Cancellation,
    ) -> Result<Restoration, Error> {
        cancel.check()?;
        if after.len() != self.outputs.len() {
            return Err(Error::Stale);
        }
        for ((doc, text), actual) in self.before.documents.iter().zip(&self.outputs).zip(&after) {
            if doc.id != actual.id || text != &actual.text {
                return Err(Error::Stale);
            }
        }
        Ok(Restoration {
            original: self.before.clone(),
            expected: after,
        })
    }
}
impl Restoration {
    pub fn restore(
        &self,
        current: &[DocumentSnapshot],
        cancel: &Cancellation,
    ) -> Result<Vec<String>, Error> {
        cancel.check()?;
        if current.len() != self.expected.len() {
            return Err(Error::Stale);
        }
        for (expected, actual) in self.expected.iter().zip(current) {
            cancel.check()?;
            if expected != actual {
                return Err(Error::Stale);
            }
        }
        let texts = self
            .original
            .documents
            .iter()
            .map(|doc| doc.preview.source().to_owned())
            .collect();
        cancel.check()?;
        Ok(texts)
    }
}
