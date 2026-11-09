//! Ein einziger GTK-freier Parserprozess; begrenzte Pipe, Laufzeit und Adressraum.
use fastra_core::folding::{Failure, Region, MAX_BYTES};
use fastra_process as process;
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Write},
    path::Path,
    sync::{mpsc, OnceLock},
    time::Duration,
};
#[cfg(debug_assertions)]
pub(super) static FINISHED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
const SWITCH: &str = "--fastra-fold-worker-v1";
const OUTPUT_BYTES: usize = 2 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
struct Envelope {
    version: u8,
    result: Result<Vec<Region>, Failure>,
}
pub(super) struct Job {
    pub language: String,
    pub source: String,
    pub cancel: process::Cancellation,
    pub reply: mpsc::Sender<Result<Vec<Region>, Failure>>,
}
pub(super) fn submit(job: Job) -> Result<(), Job> {
    static QUEUE: OnceLock<mpsc::SyncSender<Job>> = OnceLock::new();
    let sender = QUEUE.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<Job>(1);
        std::thread::Builder::new()
            .name("fastra-fold-parser".into())
            .spawn(move || {
                while let Ok(job) = rx.recv() {
                    let result = request(&job);
                    #[cfg(debug_assertions)]
                    {
                        FINISHED.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        if std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref() == Ok("1")
                            && std::env::var("FASTRA_FOLDING_SELFTEST").as_deref() == Ok("guards")
                        {
                            std::thread::sleep(Duration::from_millis(400));
                        }
                    }
                    let _ = job.reply.send(result);
                }
            })
            .ok();
        tx
    });
    match sender.try_send(job) {
        Ok(()) => Ok(()),
        Err(mpsc::TrySendError::Full(job)) => Err(job),
        Err(mpsc::TrySendError::Disconnected(job)) => {
            let _ = job.reply.send(Err(Failure::Unavailable));
            Ok(())
        }
    }
}
fn request(job: &Job) -> Result<Vec<Region>, Failure> {
    if job.cancel.is_cancelled() {
        return Err(Failure::Cancelled);
    }
    if job.source.len() > MAX_BYTES || job.language.len() > 64 {
        return Err(Failure::Limit);
    }
    let mut input = format!("fold1 {}\n", job.language).into_bytes();
    input.extend_from_slice(job.source.as_bytes());
    let executable = std::env::current_exe().map_err(|_| Failure::Unavailable)?;
    let output = process::run_with_input_in(
        process::Domain::Isolated,
        &executable,
        Path::new("/"),
        &[SWITCH.into()],
        &input,
        process::Policy {
            timeout: Duration::from_secs(5),
            termination_grace: Duration::from_millis(50),
            stdout_bytes: OUTPUT_BYTES,
            stderr_bytes: 4096,
        },
        &job.cancel,
        &process::Environment::default(),
    )
    .map_err(|error| match error {
        process::Error::Cancelled(_) => Failure::Cancelled,
        process::Error::TimedOut(_) | process::Error::OutputLimit(_) => Failure::Limit,
        _ => Failure::Unavailable,
    })?;
    if !output.success() {
        return Err(
            if output.signal.is_some_and(|signal| {
                matches!(signal, libc::SIGXCPU | libc::SIGABRT | libc::SIGKILL)
            }) {
                Failure::Limit
            } else {
                Failure::Unavailable
            },
        );
    }
    if job.cancel.is_cancelled() {
        return Err(Failure::Cancelled);
    }
    let response: Envelope =
        serde_json::from_slice(&output.stdout).map_err(|_| Failure::Unavailable)?;
    if response.version != 1 {
        return Err(Failure::Unavailable);
    }
    let regions = response.result?;
    if !fastra_core::folding::validate(
        &job.source,
        &regions,
        &fastra_core::Cancellation::default(),
    )? {
        return Err(Failure::Unavailable);
    }
    Ok(regions)
}
fn limits() -> bool {
    let parent = unsafe { libc::getppid() };
    if parent <= 1
        || unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) } != 0
        || unsafe { libc::getppid() } != parent
    {
        return false;
    }
    for (resource, soft, hard) in [
        (libc::RLIMIT_AS, 768 * 1024 * 1024, 768 * 1024 * 1024),
        (libc::RLIMIT_CPU, 4, 5),
        (libc::RLIMIT_CORE, 0, 0),
        (libc::RLIMIT_FSIZE, 0, 0),
    ] {
        if unsafe {
            libc::setrlimit(
                resource,
                &libc::rlimit {
                    rlim_cur: soft,
                    rlim_max: hard,
                },
            )
        } != 0
        {
            return false;
        }
    }
    true
}
fn parse_input() -> Result<Vec<Region>, Failure> {
    if !limits() {
        return Err(Failure::Unavailable);
    }
    let mut bytes = Vec::new();
    std::io::stdin()
        .take((MAX_BYTES + 128) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::Unavailable)?;
    let newline = bytes
        .iter()
        .position(|b| *b == b'\n')
        .filter(|n| *n <= 72)
        .ok_or(Failure::Unavailable)?;
    let header = std::str::from_utf8(&bytes[..newline]).map_err(|_| Failure::Unavailable)?;
    let language = header
        .strip_prefix("fold1 ")
        .filter(|s| !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric()))
        .ok_or(Failure::Unavailable)?;
    let source = std::str::from_utf8(&bytes[newline + 1..]).map_err(|_| Failure::Unavailable)?;
    fastra_core::folding::regions(source, language, &fastra_core::Cancellation::default())
}
pub(crate) fn entry() -> Option<i32> {
    if !std::env::args_os()
        .nth(1)
        .is_some_and(|argument| argument == SWITCH)
    {
        return None;
    }
    let result = std::panic::catch_unwind(parse_input).unwrap_or(Err(Failure::Unavailable));
    let mut bytes = serde_json::to_vec(&Envelope { version: 1, result }).unwrap_or_default();
    if bytes.len() > OUTPUT_BYTES {
        bytes = serde_json::to_vec(&Envelope {
            version: 1,
            result: Err(Failure::Limit),
        })
        .unwrap_or_default();
    }
    Some(i32::from(std::io::stdout().write_all(&bytes).is_err()))
}
