use super::*;
pub(super) fn entry() -> i32 {
    let mut token = String::new();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || -> Result<Outcome, String> {
            let mut bytes = Vec::new();
            std::io::stdin()
                .take((JSON_LIMIT + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(io)?;
            if bytes.len() > JSON_LIMIT {
                return Err("Macro worker input limit".into());
            }
            let request: Request =
                serde_json::from_slice(&bytes).map_err(|_| "Invalid macro worker request")?;
            token = request.token.clone();
            run(request)
        },
    ))
    .unwrap_or_else(|_| Err("Macro worker failed".into()));
    let mut envelope = Envelope {
        version: 1,
        token,
        result,
    };
    let mut bytes = serde_json::to_vec(&envelope).unwrap_or_default();
    if bytes.len() > JSON_LIMIT {
        envelope.result = Err("Macro worker result limit".into());
        bytes = serde_json::to_vec(&envelope).unwrap_or_default();
    }
    i32::from(std::io::stdout().write_all(&bytes).is_err())
}
fn run(request: Request) -> Result<Outcome, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    validate(&request.variant, &request.method)?;
    if request.code.len() > SOURCE_LIMIT || request.token.is_empty() || request.token.len() > 128 {
        return Err("Macro request limits".into());
    }
    let project = Path::new(&request.project);
    if project.is_absolute()
        || project
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        || project
            .extension()
            .is_none_or(|e| !e.eq_ignore_ascii_case("4dproject"))
    {
        return Err("Invalid engine project path".into());
    }
    // Fremde Bibliotheken werden erst nach dem identischen Runtime-Proof wie im Leseadapter geladen.
    let _held =
        runtime::verify_runtime_mounts(Path::new("/runtime"), &request.runtime).map_err(io)?;
    if request.parent_net.len() > 128
        || fs::read_link("/proc/self/ns/net")
            .map_err(io)?
            .to_string_lossy()
            == request.parent_net
    {
        return Err("Macro worker network namespace is not isolated".into());
    }
    if fs::read_to_string("/proc/net/dev")
        .map_err(io)?
        .lines()
        .skip(2)
        .filter_map(|l| l.split_once(':'))
        .any(|(name, _)| name.trim() != "lo")
    {
        return Err("Only isolated loopback is allowed".into());
    }
    let meta = fs::symlink_metadata("/engine").map_err(io)?;
    if !meta.is_dir() || (meta.dev(), meta.ino()) != request.project_identity {
        return Err("Mounted engine identity changed".into());
    }
    let project = Path::new("/engine").join(project);
    let _project = crate::open_path(&project, false)?;
    if !_project.metadata().map_err(io)?.is_file() {
        return Err("Regular engine project file required".into());
    }
    let input = Path::new("/output/input.4dm");
    let output = Path::new("/output/output.4dm");
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(input)
        .map_err(io)?
        .write_all(request.code.as_bytes())
        .map_err(io)?;
    let args = arguments(&project, input, output, &request.variant, &request.method)?;
    let result = process::run_in(
        process::Domain::Isolated,
        Path::new("/runtime/tool4d"),
        Path::new("/tmp"),
        &args,
        Policy {
            timeout: TIMEOUT,
            termination_grace: Duration::from_millis(100),
            stdout_bytes: 32 * 1024,
            stderr_bytes: 32 * 1024,
        },
        &process::Cancellation::default(),
        &Environment {
            remove_prefixes: vec!["LD_".into(), "GCONV_PATH".into()],
            set: vec![("LD_LIBRARY_PATH".into(), "/runtime/lib".into())],
        },
    );
    // Auch eine früh geschriebene OK-Datei macht einen abgebrochenen/ausufernden Lauf nicht vollständig.
    let process = match result {
        Ok(output) => output,
        Err(process::Error::TimedOut(_)) => {
            return Err("MacroRun timed out after 60 seconds and was stopped".into())
        }
        Err(process::Error::Cancelled(_)) => return Err("MacroRun was cancelled".into()),
        Err(process::Error::OutputLimit(_)) => {
            return Err("MacroRun exceeded its process output limit and was stopped".into())
        }
        Err(e) => return Err(io(e)),
    };
    let status = bounded_file(Path::new("/output/output.4dm.status"), STATUS_LIMIT)?;
    let output = if status.as_deref().is_some_and(|s| s.trim() == "OK") {
        bounded_file(output, OUTPUT_LIMIT)?
    } else {
        None
    };
    interpret(status.as_deref(), output).map_err(|e| {
        if status.is_none() {
            format!(
                "{e}\nTool4D exit {:?}, signal {:?}: {}",
                process.exit_code,
                process.signal,
                String::from_utf8_lossy(&process.stderr)
            )
        } else {
            e
        }
    })
}
