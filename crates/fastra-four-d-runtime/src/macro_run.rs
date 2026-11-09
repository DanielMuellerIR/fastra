//! Ausdrücklich gestartete MacroRun-Läufe in einer eigenen Schreib-Sandbox.
use crate::read::{self as runtime, RuntimeProofs};
use fastra_core::{four_d, Cancellation, Limits};
use fastra_process::{self as process, Environment, Policy};
use serde::{Deserialize, Serialize};
use std::{
    ffi::OsString,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Condvar, Mutex, OnceLock,
    },
    time::Duration,
};
mod private_project;
mod sandbox;
#[cfg(test)]
mod tests;
mod worker;
const SOURCE_LIMIT: usize = 4 * 1024 * 1024;
const OUTPUT_LIMIT: usize = 8 * 1024 * 1024;
const STATUS_LIMIT: usize = 16 * 1024;
const JSON_LIMIT: usize = 32 * 1024 * 1024;
pub(crate) const TIMEOUT: Duration = Duration::from_secs(60);
const VARIANTS: [&str; 4] = [
    "komplettieren",
    "komplettieren-ohne-nv",
    "komplettieren-ohne-var",
    "komplettieren-ohne-nv-var",
];
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Changed(String),
    Unchanged,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    runtime: RuntimeProofs,
    parent_net: String,
    project: String,
    project_identity: (u64, u64),
    code: String,
    variant: String,
    method: String,
    token: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    token: String,
    result: Result<Outcome, String>,
}
fn check(cancel: &Cancellation) -> Result<(), String> {
    cancel.check().map_err(|e| e.to_string())
}
fn io(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn validate(variant: &str, method: &str) -> Result<(), String> {
    if !VARIANTS.contains(&variant) {
        return Err("Unsupported MacroRun variant".into());
    }
    if method.is_empty() || method.len() > 1024 || method.contains(['|', '\0', '\r', '\n']) {
        return Err("MacroRun method name must not contain |, NUL or a line break".into());
    }
    if method == "00_DM_Info" || method.starts_with("Compiler_") {
        return Err("00_DM_Info and Compiler_* methods are excluded from completion macros".into());
    }
    Ok(())
}
fn arguments(
    project: &Path,
    input: &Path,
    output: &Path,
    variant: &str,
    method: &str,
) -> Result<Vec<OsString>, String> {
    validate(variant, method)?;
    let paths = [project, input, output].map(|p| p.to_str().ok_or("MacroRun paths must be UTF-8"));
    let [project, input, output] = paths;
    let (project, input, output) = (project?, input?, output?);
    if [input, output].iter().any(|p| p.contains(['|', '\0'])) {
        return Err("MacroRun input/output paths must not contain | or NUL".into());
    }
    Ok(vec![
        "--project".into(),
        project.into(),
        "--dataless".into(),
        "--skip-onstartup".into(),
        "--opening-mode".into(),
        "interpreted".into(),
        "--startup-method".into(),
        "MacroRun".into(),
        "--user-param".into(),
        format!("{input}|{output}|{variant}|{method}").into(),
    ])
}
fn interpret(status: Option<&str>, output: Option<String>) -> Result<Outcome, String> {
    let line = status
        .ok_or(
            "Tool4D did not write a status file. The selected engine project requires MacroRun.",
        )?
        .trim();
    if line == "OK" {
        return output
            .filter(|s| !s.is_empty())
            .map(Outcome::Changed)
            .ok_or("Status OK, but result file is missing or empty".into());
    }
    if line == "UNVERAENDERT" {
        return Ok(Outcome::Unchanged);
    }
    if let Some(detail) = line.strip_prefix("FEHLER") {
        return Err(if detail.trim().is_empty() {
            "MacroRun reported an error without details".into()
        } else {
            detail.trim().into()
        });
    }
    Err(format!("Unrecognized MacroRun status: {line}"))
}
fn bounded_file(path: &Path, limit: usize) -> Result<Option<String>, String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(io(e)),
    };
    let meta = file.metadata().map_err(io)?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err(format!("Regular UTF-8 result up to {limit} bytes required"));
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() > limit || bytes.len() != meta.len() as usize {
        return Err("Result changed during bounded read".into());
    }
    String::from_utf8(bytes)
        .map(|s| Some(s.strip_prefix('\u{feff}').unwrap_or(&s).to_owned()))
        .map_err(|_| "MacroRun result is not valid UTF-8".into())
}
// FIFO statt eines blockierenden Mutex: wartende Fenster können ihren Auftrag abbrechen.
static QUEUE: OnceLock<(Mutex<std::collections::VecDeque<u64>>, Condvar)> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
struct Slot(u64);
impl Slot {
    fn acquire(cancel: &Cancellation) -> Result<Self, String> {
        let (mutex, wake) = QUEUE.get_or_init(Default::default);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let mut queue = mutex.lock().map_err(io)?;
        queue.push_back(id);
        loop {
            if let Err(e) = check(cancel) {
                queue.retain(|n| *n != id);
                wake.notify_all();
                return Err(e);
            }
            if queue.front() == Some(&id) {
                return Ok(Self(id));
            }
            queue = wake
                .wait_timeout(queue, Duration::from_millis(20))
                .map_err(io)?
                .0;
        }
    }
}
impl Drop for Slot {
    fn drop(&mut self) {
        let (mutex, wake) = QUEUE.get().unwrap();
        if let Ok(mut queue) = mutex.lock() {
            queue.retain(|n| *n != self.0);
            wake.notify_all();
        }
    }
}
pub struct Query<'a> {
    pub runtime: &'a Path,
    pub engine: &'a Path,
    pub original: &'a str,
    pub variant: &'a str,
    pub method: &'a str,
    pub cancel: &'a Cancellation,
    pub process_cancel: &'a process::Cancellation,
    pub should_start: &'a (dyn Fn() -> bool + Sync),
}
/// Auf einer Hintergrundqueue. Die UI bestätigt die vollständige Lease nach Erhalt des seriellen Slots erneut.
pub fn execute(query: Query<'_>) -> Result<Outcome, String> {
    validate(query.variant, query.method)?;
    check(query.cancel)?;
    if query.original.len() > SOURCE_LIMIT {
        return Err("MacroRun source limit: 4 MiB".into());
    }
    let _slot = Slot::acquire(query.cancel)?;
    let verify = || -> Result<(), String> {
        check(query.cancel)?;
        if !(query.should_start)() {
            return Err(
                "Document, selection, path, window or project changed before MacroRun start".into(),
            );
        }
        Ok(())
    };
    verify()?;
    let learned =
        four_d::learned_suffixes(query.original, Limits::default(), query.cancel).map_err(io)?;
    let code = four_d::transform_tokens(
        query.original,
        four_d::TokenTransform::Detokenize,
        Limits::default(),
        query.cancel,
    )
    .map_err(io)?;
    let runtime = runtime::runtime(query.runtime).map_err(io)?;
    let directory = tempfile::Builder::new()
        .prefix("fastra-macro-")
        .tempdir()
        .map_err(io)?;
    let project =
        private_project::copy(query.engine, &directory.path().join("engine"), query.cancel)?;
    verify()?;
    let token = format!(
        "{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let result = sandbox::execute(
        &runtime,
        directory.path(),
        &project,
        &code,
        query.variant,
        query.method,
        &token,
        query.cancel,
        query.process_cancel,
        &verify,
    )?;
    check(query.cancel)?;
    match result {
        Outcome::Changed(text) => {
            let text = text.replace("\r\n", "\n").replace('\r', "\n");
            let result = four_d::retokenize(
                &text,
                &learned,
                Limits {
                    max_output_bytes: OUTPUT_LIMIT,
                    ..Default::default()
                },
                query.cancel,
            )
            .map_err(io)?;
            Ok(if result == query.original {
                Outcome::Unchanged
            } else {
                Outcome::Changed(result)
            })
        }
        other => Ok(other),
    }
}
pub fn worker_entry() -> Option<i32> {
    (std::env::args_os().nth(1).as_deref()
        == Some(std::ffi::OsStr::new("--fastra-4d-macro-worker")))
    .then(worker::entry)
}
