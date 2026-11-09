//! Lokaler, rein lesender Steuerungsvertrag; ohne Fenster- oder Dateizugriffe.
pub use crate::code_explanation::Id as UUID;
use crate::{code_explanation::Id, Cancellation};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
pub const MAX_REQUEST: usize = 65_536;
pub const MAX_REPLY: usize = 16 * 1024 * 1024;
pub const MAX_SNAPSHOT: usize = 262_144;
pub const MAX_OUTER: usize = 67_108_864;
pub const MAX_JOBS: usize = 128;
pub const MAX_SESSIONS: usize = 16;
pub const RETENTION: f64 = 300.;
pub const JOB_TIMEOUT: f64 = 30.;
pub const OPERATIONS: [&str; 9] = [
    "capabilities",
    "objects",
    "snapshot",
    "sourceSnapshot",
    "explanation",
    "status",
    "cancel",
    "navigate",
    "close",
];
pub const ENCODINGS: [&str; 6] = [
    "utf-8",
    "utf-16-le",
    "utf-16-be",
    "windows-1252",
    "iso-8859-1",
    "mac-roman",
];
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Failure {
    pub code: String,
    pub message: String,
    pub apple_script_number: i32,
}
impl Failure {
    pub fn new(code: &str) -> Self {
        let (message, n) = match code {
            "invalidRequest" => ("The control request is invalid.", -1700),
            "unsupported" => (
                "This control operation or protocol is not supported.",
                -1708,
            ),
            "invalidID" => (
                "The runtime object no longer exists or belongs to another app run.",
                -1728,
            ),
            "stale" => (
                "The expected source or document binding does not match.",
                -2700,
            ),
            "invalidRange" => (
                "The selection must be within the text and on complete character boundaries.",
                -2700,
            ),
            "sourceUnavailable" => (
                "The source is unavailable or is not supported bounded text.",
                -2700,
            ),
            "capacity" => ("The control session or job limit has been reached.", -2700),
            "expired" => ("The control request or job deadline has elapsed.", -2700),
            "interrupted" => ("The selection changed while navigation was pending.", -2700),
            _ => (
                "Fastra did not confirm the control request before the deadline.",
                -2700,
            ),
        };
        Self {
            code: code.into(),
            message: message.into(),
            apple_script_number: n,
        }
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for Failure {}
pub type Result<T> = std::result::Result<T, Failure>;
fn fail<T>(code: &str) -> Result<T> {
    Err(Failure::new(code))
}
pub fn valid_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub location: i64,
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub length: i64,
}
impl Selection {
    pub fn validate(&self, text: &str, cancel: &Cancellation) -> Result<()> {
        if self.location < 0 || self.length < 0 || self.location.checked_add(self.length).is_none()
        {
            return fail("invalidRange");
        }
        crate::code_explanation::validate_range(
            text,
            self.location as usize,
            self.length as usize,
            cancel,
        )
        .map_err(|_| Failure::new("invalidRange"))
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceGeneration {
    #[serde(deserialize_with = "crate::json_integer::u64")]
    pub device: u64,
    #[serde(deserialize_with = "crate::json_integer::u64")]
    pub inode: u64,
    #[serde(deserialize_with = "crate::json_integer::u64")]
    pub size: u64,
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub modification_seconds: i64,
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub modification_nanoseconds: i64,
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub change_seconds: i64,
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub change_nanoseconds: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HitIdentity {
    pub filesystem_path: String,
    pub archive_members: Vec<String>,
    pub archive_member_bytes: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Provenance {
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub schema_version: i64,
    #[serde(rename = "runID")]
    pub run_id: Id,
    pub kind: String,
    pub hit_identity: HitIdentity,
    pub source_generation: SourceGeneration,
    pub archive_binding: String,
    #[serde(rename = "outerSHA256", skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub outer_sha256: Option<String>,
    pub position_binding: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub search_evidence: Option<String>,
}
// Kanonisches Base64 wird hier ohne tolerante Decoderoptionen geprüft.
fn base64(s: &str) -> Option<Vec<u8>> {
    if s.is_empty() || s.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::new();
    for (index, part) in s.as_bytes().chunks_exact(4).enumerate() {
        let mut v = [0u8; 4];
        let mut padding = 0;
        for i in 0..4 {
            v[i] = match part[i] {
                b'A'..=b'Z' => part[i] - b'A',
                b'a'..=b'z' => part[i] - b'a' + 26,
                b'0'..=b'9' => part[i] - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' if i >= 2 => {
                    padding += 1;
                    0
                }
                _ => return None,
            };
            if padding > 0 && part[i] != b'=' {
                return None;
            }
        }
        if padding > 0 && index + 1 != s.len() / 4 {
            return None;
        }
        if padding == 2 && v[1] & 15 != 0 || padding == 1 && v[2] & 3 != 0 {
            return None;
        }
        out.push(v[0] << 2 | v[1] >> 4);
        if padding < 2 {
            out.push(v[1] << 4 | v[2] >> 2)
        }
        if padding == 0 {
            out.push(v[2] << 6 | v[3])
        }
    }
    Some(out)
}
fn lexical(path: &str) -> String {
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}
impl Provenance {
    pub fn validate(&self, path: &str, selection: &Selection) -> Result<()> {
        let h = &self.hit_identity;
        let g = &self.source_generation;
        if self.schema_version != 1
            || !matches!(self.kind.as_str(), "original" | "archiveMaterialization")
            || !h.filesystem_path.starts_with('/')
            || h.filesystem_path.contains('\0')
            || h.filesystem_path.len() > 16_384
            || h.archive_members.len() > 32
            || h.archive_members.len() != h.archive_member_bytes.len()
            || !(0..1_000_000_000).contains(&g.modification_nanoseconds)
            || !(0..1_000_000_000).contains(&g.change_nanoseconds)
            || !matches!(self.position_binding.as_str(), "exactUTF16" | "unboundHit")
            || self.position_binding == "unboundHit"
                && (selection.location != 0 || selection.length != 0)
            || self
                .search_evidence
                .as_ref()
                .is_some_and(|s| s.len() > 4096 || s.contains('\0'))
        {
            return fail("invalidRequest");
        }
        for (name, raw) in h.archive_members.iter().zip(&h.archive_member_bytes) {
            let bytes = base64(raw).ok_or_else(|| Failure::new("invalidRequest"))?;
            if name.is_empty()
                || name.len() > 4096
                || name.contains('\0')
                || bytes.is_empty()
                || bytes.len() > 4096
                || bytes.contains(&0)
                || std::str::from_utf8(&bytes).is_ok_and(|s| s != name)
            {
                return fail("invalidRequest");
            }
        }
        if self.kind == "original" {
            if !h.archive_members.is_empty()
                || self.archive_binding != "notApplicable"
                || self.outer_sha256.is_some()
                || lexical(path) != lexical(&h.filesystem_path)
            {
                return fail("invalidRequest");
            }
        } else if h.archive_members.is_empty()
            || match self.archive_binding.as_str() {
                "sha256" => !self.outer_sha256.as_ref().is_some_and(|s| valid_hash(s)),
                "generation" => self.outer_sha256.is_some(),
                _ => true,
            }
        {
            return fail("invalidRequest");
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub version: i64,
    pub id: Id,
    pub deadline: f64,
    pub operation: String,
    #[serde(rename = "runtimeID", skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub runtime_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::optional_i64")]
    pub location: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::optional_i64")]
    pub length: Option<i64>,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub session_id: Option<Id>,
    #[serde(rename = "documentID", skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub document_id: Option<Id>,
    #[serde(rename = "jobID", skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub job_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub provenance: Option<Provenance>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default, deserialize_with = "crate::json_integer::non_null")]
    pub text_encoding: Option<String>,
}
impl Request {
    pub fn new(operation: &str, id: Id, now: f64) -> Self {
        Self {
            version: 1,
            id,
            deadline: now + 10.,
            operation: operation.into(),
            runtime_id: None,
            path: None,
            sha256: None,
            location: None,
            length: None,
            session_id: None,
            document_id: None,
            job_id: None,
            provenance: None,
            text_encoding: None,
        }
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_REQUEST {
            return fail("invalidRequest");
        }
        // Typisierte Deserialisierung erhält Zahltexte, doppelte/unerwartete Felder
        // und die Unterscheidung zwischen fehlenden und expliziten null-Feldern.
        serde_json::from_slice(bytes).map_err(|_| Failure::new("invalidRequest"))
    }
    pub fn selection(&self) -> Selection {
        Selection {
            location: self.location.unwrap_or(0),
            length: self.length.unwrap_or(0),
        }
    }
    pub fn equivalent(&self, other: &Self) -> bool {
        use unicode_normalization::UnicodeNormalization;
        fn eq(a: &serde_json::Value, b: &serde_json::Value) -> bool {
            match (a, b) {
                (serde_json::Value::String(a), serde_json::Value::String(b)) => a.nfc().eq(b.nfc()),
                (serde_json::Value::Object(a), serde_json::Value::Object(b)) => {
                    a.len() == b.len()
                        && a.iter()
                            .all(|(k, v)| b.get(k).is_some_and(|other| eq(v, other)))
                }
                (serde_json::Value::Array(a), serde_json::Value::Array(b)) => {
                    a.len() == b.len() && a.iter().zip(b).all(|(a, b)| eq(a, b))
                }
                _ => a == b,
            }
        }
        // Swift-Equatable vergleicht String kanonisch; die tatsächlichen Quellpfade bleiben unverändert.
        match (serde_json::to_value(self), serde_json::to_value(other)) {
            (Ok(a), Ok(b)) => eq(&a, &b),
            _ => false,
        }
    }
    pub fn mutates(&self) -> bool {
        matches!(
            self.operation.as_str(),
            "snapshot" | "sourceSnapshot" | "explanation" | "navigate" | "cancel" | "close"
        )
    }
    pub fn cleanup(&self) -> bool {
        matches!(self.operation.as_str(), "cancel" | "close")
    }
    pub fn validate(&self, now: f64, allow_expired: bool) -> Result<()> {
        if self.version != 1 || !OPERATIONS.contains(&self.operation.as_str()) {
            return fail("unsupported");
        }
        if !self.deadline.is_finite()
            || self.deadline <= 0.
            || !allow_expired && self.deadline <= now
            || self.deadline > now + 11.
        {
            return fail("expired");
        }
        if self
            .text_encoding
            .as_ref()
            .is_some_and(|e| self.operation != "sourceSnapshot" || !ENCODINGS.contains(&e.as_str()))
        {
            return fail("invalidRequest");
        }
        let actual = [
            self.path.is_some(),
            self.sha256.is_some(),
            self.location.is_some(),
            self.length.is_some(),
            self.session_id.is_some(),
            self.document_id.is_some(),
            self.job_id.is_some(),
            self.provenance.is_some(),
        ];
        let expected = match self.operation.as_str() {
            "snapshot" => [true, true, true, true, false, false, false, false],
            "sourceSnapshot" => [true, true, true, true, false, false, false, true],
            "explanation" => [true, false, false, false, false, false, false, false],
            "navigate" => [false, true, true, true, true, true, false, false],
            "status" | "cancel" => [false, false, false, false, false, false, true, false],
            "close" => [false, false, false, false, true, false, false, false],
            _ => [false; 8],
        };
        if actual != expected
            || self
                .path
                .as_ref()
                .is_some_and(|p| !p.starts_with('/') || p.contains('\0'))
            || self.sha256.as_ref().is_some_and(|s| !valid_hash(s))
        {
            return fail("invalidRequest");
        }
        let s = self.selection();
        if s.location < 0 || s.length < 0 || s.location.checked_add(s.length).is_none() {
            return fail("invalidRange");
        }
        if let Some(p) = &self.provenance {
            p.validate(self.path.as_deref().unwrap_or(""), &s)?
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Object {
    pub id: Id,
    pub kind: String,
    pub name: String,
    #[serde(rename = "windowID", skip_serializing_if = "Option::is_none")]
    pub window_id: Option<Id>,
    #[serde(rename = "documentID", skip_serializing_if = "Option::is_none")]
    pub document_id: Option<Id>,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<Selection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Provenance>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: Id,
    #[serde(rename = "requestID")]
    pub request_id: Id,
    pub state: String,
    #[serde(rename = "sessionID")]
    pub session_id: Id,
    #[serde(rename = "windowID")]
    pub window_id: Id,
    #[serde(rename = "documentID")]
    pub document_id: Id,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(rename = "textSHA256", skip_serializing_if = "Option::is_none")]
    pub text_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub byte_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encoding: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bom_bytes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<Selection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<Failure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Provenance>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub adopted: Option<bool>,
}
impl Job {
    pub fn new(id: Id, request: &Request, session: Id, window: Id, document: Id) -> Self {
        Self {
            id,
            request_id: request.id.clone(),
            state: "accepted".into(),
            session_id: session,
            window_id: window,
            document_id: document,
            sha256: None,
            text_sha256: None,
            byte_count: None,
            encoding: None,
            bom_bytes: None,
            selection: None,
            error: None,
            provenance: request.provenance.clone(),
            adopted: request.provenance.as_ref().map(|_| false),
        }
    }
    pub fn terminal(&self) -> bool {
        matches!(self.state.as_str(), "ready" | "failed" | "cancelled")
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub protocol_version: u32,
    pub operations: Vec<String>,
    pub source_kinds: Vec<String>,
    pub source_snapshot_schema_version: u32,
    pub source_snapshot_text_encodings: Vec<String>,
    pub maximum_outer_archive_bytes: usize,
    pub coordinates: String,
    pub read_only: bool,
    pub maximum_snapshot_bytes: usize,
    pub maximum_message_bytes: usize,
    pub request_timeout_seconds: f64,
    pub job_timeout_seconds: f64,
    pub retention_seconds: f64,
    pub maximum_jobs: usize,
    pub explanation_schema_version: u32,
    pub maximum_explanation_steps: usize,
    pub maximum_explanation_total_source_bytes: usize,
    pub explanation_encodings: Vec<String>,
    pub maximum_sessions: usize,
    #[serde(rename = "runtimeID", skip_serializing_if = "Option::is_none")]
    pub runtime_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product_version: Option<String>,
}
impl Default for Capabilities {
    fn default() -> Self {
        Self {
            protocol_version: 1,
            operations: OPERATIONS.iter().map(|s| s.to_string()).collect(),
            source_kinds: vec!["fileSnapshot".into(), "archiveMaterialization".into()],
            source_snapshot_schema_version: 1,
            source_snapshot_text_encodings: ENCODINGS.iter().map(|s| s.to_string()).collect(),
            maximum_outer_archive_bytes: MAX_OUTER,
            coordinates:
                "zero-based UTF-16; start inclusive, end exclusive; grapheme boundaries required"
                    .into(),
            read_only: true,
            maximum_snapshot_bytes: MAX_SNAPSHOT,
            maximum_message_bytes: MAX_REQUEST,
            request_timeout_seconds: 10.,
            job_timeout_seconds: JOB_TIMEOUT,
            retention_seconds: RETENTION,
            maximum_jobs: MAX_JOBS,
            explanation_schema_version: 1,
            maximum_explanation_steps: 5,
            maximum_explanation_total_source_bytes: 1_048_576,
            explanation_encodings: vec!["utf8".into()],
            maximum_sessions: MAX_SESSIONS,
            runtime_id: None,
            product_version: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub protocol_version: u32,
    #[serde(rename = "runtimeID", skip_serializing_if = "Option::is_none")]
    pub runtime_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Capabilities>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub objects: Option<Vec<Object>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jobs: Option<Vec<Job>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<Job>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<Failure>,
}
impl Reply {
    pub fn new(runtime: Option<Id>) -> Self {
        Self {
            protocol_version: 1,
            runtime_id: runtime,
            capabilities: None,
            objects: None,
            jobs: None,
            job: None,
            error: None,
        }
    }
    pub fn failure(runtime: Option<Id>, error: Failure) -> Self {
        let mut r = Self::new(runtime);
        r.error = Some(error);
        r
    }
}
struct Accepted {
    request: Request,
    job: Option<Id>,
    expires: f64,
}
pub struct State {
    pub runtime_id: Id,
    pub jobs: BTreeMap<Id, Job>,
    created: BTreeMap<Id, f64>,
    accepted: BTreeMap<Id, Accepted>,
    cleanup: BTreeMap<Id, Accepted>,
}
impl State {
    pub fn new(runtime_id: Id) -> Self {
        Self {
            runtime_id,
            jobs: BTreeMap::new(),
            created: BTreeMap::new(),
            accepted: BTreeMap::new(),
            cleanup: BTreeMap::new(),
        }
    }
    pub fn prune(&mut self, now: f64) {
        for (id, job) in &mut self.jobs {
            if !job.terminal() && now - self.created[id] >= JOB_TIMEOUT {
                job.state = "failed".into();
                job.error = Some(Failure::new("expired"));
            }
        }
        self.jobs.retain(|id, _| now - self.created[id] < RETENTION);
        self.created.retain(|id, _| self.jobs.contains_key(id));
        self.accepted.retain(|_, v| v.expires > now);
        self.cleanup.retain(|_, v| v.expires > now);
    }
    pub fn prepare(&mut self, r: &Request, now: f64) -> Result<Option<Reply>> {
        self.prune(now);
        if r.runtime_id
            .as_ref()
            .is_some_and(|id| id != &self.runtime_id)
        {
            return fail("invalidID");
        }
        if r.mutates() {
            if let Some(old) = self.accepted.get(&r.id).or_else(|| self.cleanup.get(&r.id)) {
                if !old.request.equivalent(r) {
                    return fail("invalidRequest");
                }
                let mut reply = Reply::new(Some(self.runtime_id.clone()));
                reply.job = old.job.as_ref().and_then(|id| self.jobs.get(id)).cloned();
                return Ok(Some(reply));
            }
        }
        r.validate(now, false)?;
        if r.mutates() && !r.cleanup() && self.accepted.len() >= MAX_JOBS * 2 {
            return fail("capacity");
        }
        Ok(None)
    }
    pub fn record(&mut self, r: &Request, reply: &Reply, now: f64) {
        if !r.mutates() {
            return;
        }
        let map = if r.cleanup() {
            &mut self.cleanup
        } else {
            &mut self.accepted
        };
        if r.cleanup() && map.len() >= MAX_JOBS * 2 {
            if let Some(id) = map
                .iter()
                .min_by(|a, b| a.1.expires.total_cmp(&b.1.expires))
                .map(|(id, _)| id.clone())
            {
                map.remove(&id);
            }
        }
        map.insert(
            r.id.clone(),
            Accepted {
                request: r.clone(),
                job: reply.job.as_ref().map(|j| j.id.clone()),
                expires: now + RETENTION,
            },
        );
    }
    pub fn insert(&mut self, job: Job, now: f64) -> Result<()> {
        if self.jobs.len() >= MAX_JOBS {
            return fail("capacity");
        }
        self.created.insert(job.id.clone(), now);
        self.jobs.insert(job.id.clone(), job);
        Ok(())
    }
    pub fn pending(&self, id: &Id, now: f64) -> bool {
        self.jobs.get(id).is_some_and(|j| !j.terminal())
            && self
                .created
                .get(id)
                .is_some_and(|created| now - created < JOB_TIMEOUT)
    }
    pub fn cancel(&mut self, id: &Id) -> Result<()> {
        let job = self
            .jobs
            .get_mut(id)
            .ok_or_else(|| Failure::new("invalidID"))?;
        if !job.terminal() {
            job.state = "cancelled".into();
        }
        Ok(())
    }
}
