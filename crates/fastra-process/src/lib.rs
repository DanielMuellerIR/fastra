//! Synchroner Unix-Prozessbesitz mit begrenzter Ausgabe und kontrolliertem Abbruch.
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
}
impl Output {
    pub fn empty() -> Self {
        Self {
            exit_code: None,
            signal: None,
            stdout: Vec::new(),
            stderr: Vec::new(),
            stdout_truncated: false,
            stderr_truncated: false,
        }
    }
    pub fn success(&self) -> bool {
        self.exit_code == Some(0)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Unavailable,
    Launch(String),
    InvalidPolicy,
    Cancelled(Output),
    TimedOut(Output),
    OutputLimit(Output),
    Capture { message: String, output: Output },
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
#[derive(Debug, Clone, Copy)]
pub struct Policy {
    pub timeout: Duration,
    pub termination_grace: Duration,
    pub stdout_bytes: usize,
    pub stderr_bytes: usize,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(120),
            termination_grace: Duration::from_millis(100),
            stdout_bytes: 16 * 1024 * 1024,
            stderr_bytes: 4 * 1024 * 1024,
        }
    }
}
#[derive(Debug, Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

#[derive(Debug, Clone, Default)]
pub struct Environment {
    pub remove_prefixes: Vec<OsString>,
    pub set: Vec<(OsString, OsString)>,
}
use std::{
    ffi::OsString,
    fs::File,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, IntoRawFd},
        unix::{
            ffi::OsStrExt,
            process::{CommandExt, ExitStatusExt},
        },
    },
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct OwnedChild {
    child: Child,
    pid: i32,
    reaped: bool,
}
impl OwnedChild {
    fn signal(&self, signal: i32) {
        // Der unreapete Gruppenleiter reserviert seine PID bis zum letzten Signal.
        unsafe {
            libc::kill(-self.pid, signal);
        }
    }
    fn exited(&self) -> io::Result<bool> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { info.si_pid() } != 0)
    }
    fn reap(&mut self) -> io::Result<std::process::ExitStatus> {
        let status = self.child.wait()?;
        self.reaped = true;
        Ok(status)
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if !self.reaped {
            self.signal(libc::SIGKILL);
            let _ = self.child.wait();
        }
    }
}
fn nonblocking(file: &File) -> io::Result<()> {
    let fd = file.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
struct Capture {
    pipe: Option<File>,
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}
impl Capture {
    fn drain(&mut self) -> io::Result<()> {
        let Some(pipe) = &mut self.pipe else {
            return Ok(());
        };
        let mut buffer = [0u8; 8192];
        // Auch ein ständig schreibender Prozess darf Abbruchprüfungen nicht verdrängen.
        for _ in 0..16 {
            match pipe.read(&mut buffer) {
                Ok(0) => {
                    self.pipe = None;
                    break;
                }
                Ok(count) => {
                    let accepted = count.min(self.limit.saturating_sub(self.bytes.len()));
                    self.bytes.extend_from_slice(&buffer[..accepted]);
                    self.exceeded |= accepted < count;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}
#[derive(Clone, Copy)]
enum Stop {
    Cancelled,
    Timeout,
    Output,
    Capture,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ParentLoss {
    #[default]
    Unchanged,
    /// Linux signalisiert nur den direkten Prozess. Nachkommen besitzt weiterhin das Werkzeug.
    Terminate,
}
pub fn run(
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
) -> Result<Output, Error> {
    run_inner(
        executable,
        directory,
        arguments,
        None,
        policy,
        cancellation,
        environment,
        ParentLoss::Unchanged,
        None,
    )
}
pub type StderrObserver<'a> = &'a mut dyn FnMut(&[u8]);
/// Der Callback läuft synchron im Owner-Loop und erhält nur begrenzt akzeptierte stderr-Bytes.
/// Er muss ohne Warten zurückkehren; UTF-8-Zeichen und Zeilen können fragmentiert sein.
#[allow(clippy::too_many_arguments)]
pub fn run_with_stderr(
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
    parent_loss: ParentLoss,
    stderr: &mut dyn FnMut(&[u8]),
) -> Result<Output, Error> {
    run_inner(
        executable,
        directory,
        arguments,
        None,
        policy,
        cancellation,
        environment,
        parent_loss,
        Some(stderr),
    )
}
/// Die anonyme Eingabepipe wird im selben begrenzten Owner-Loop wie stdout/stderr bedient.
pub fn run_with_input(
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    input: &[u8],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
) -> Result<Output, Error> {
    if input.len() > MAX_INPUT_BYTES {
        return Err(Error::InvalidPolicy);
    }
    run_inner(
        executable,
        directory,
        arguments,
        Some(input),
        policy,
        cancellation,
        environment,
        ParentLoss::Unchanged,
        None,
    )
}
pub const MAX_INPUT_BYTES: usize = 8 * 1024 * 1024;
#[cfg(target_os = "linux")]
pub mod host;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Domain {
    Host,
    Bundled,
    /// Lokaler Sandboxworker ohne geerbte Host-Fähigkeit.
    Isolated,
}
/// Gebündelte interne Helfer bleiben ausdrücklich im privaten Laufzeitraum.
pub fn run_in(
    domain: Domain,
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
) -> Result<Output, Error> {
    dispatch(
        domain,
        executable,
        directory,
        arguments,
        None,
        policy,
        cancellation,
        environment,
        ParentLoss::Unchanged,
        None,
    )
}
#[allow(clippy::too_many_arguments)]
pub fn run_with_input_in(
    domain: Domain,
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    input: &[u8],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
) -> Result<Output, Error> {
    // Der isolierte lokale Dokumentparser übernimmt bis zu 32 MiB Quellbytes
    // plus einen kleinen Protokollkopf; Hostkanäle behalten ihre 8-MiB-Grenze.
    let limit = if domain == Domain::Isolated {
        32 * 1024 * 1024 + 128
    } else {
        MAX_INPUT_BYTES
    };
    if input.len() > limit {
        return Err(Error::InvalidPolicy);
    }
    dispatch(
        domain,
        executable,
        directory,
        arguments,
        Some(input),
        policy,
        cancellation,
        environment,
        ParentLoss::Unchanged,
        None,
    )
}
#[allow(clippy::too_many_arguments)]
pub fn run_with_stderr_in(
    domain: Domain,
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
    parent_loss: ParentLoss,
    stderr: &mut dyn FnMut(&[u8]),
) -> Result<Output, Error> {
    dispatch(
        domain,
        executable,
        directory,
        arguments,
        None,
        policy,
        cancellation,
        environment,
        parent_loss,
        Some(stderr),
    )
}
#[allow(clippy::too_many_arguments)]
fn run_inner(
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    input: Option<&[u8]>,
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
    parent_loss: ParentLoss,
    stderr_observer: Option<StderrObserver<'_>>,
) -> Result<Output, Error> {
    dispatch(
        Domain::Host,
        executable,
        directory,
        arguments,
        input,
        policy,
        cancellation,
        environment,
        parent_loss,
        stderr_observer,
    )
}
#[allow(clippy::too_many_arguments)]
fn dispatch(
    domain: Domain,
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    input: Option<&[u8]>,
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
    parent_loss: ParentLoss,
    mut stderr_observer: Option<StderrObserver<'_>>,
) -> Result<Output, Error> {
    #[cfg(target_os = "linux")]
    if domain == Domain::Host {
        if let Some(result) = host::invoke(
            executable,
            directory,
            arguments,
            input,
            policy,
            cancellation,
            environment,
            parent_loss,
            &mut stderr_observer,
        ) {
            return result;
        }
    }
    run_local(
        domain,
        executable,
        directory,
        arguments,
        input,
        policy,
        cancellation,
        environment,
        parent_loss,
        stderr_observer,
    )
}
#[allow(clippy::too_many_arguments)]
fn run_local(
    domain: Domain,
    executable: &Path,
    directory: &Path,
    arguments: &[OsString],
    input: Option<&[u8]>,
    policy: Policy,
    cancellation: &Cancellation,
    environment: &Environment,
    parent_loss: ParentLoss,
    mut stderr_observer: Option<StderrObserver<'_>>,
) -> Result<Output, Error> {
    #[cfg(not(target_os = "linux"))]
    let _ = domain;
    if cancellation.is_cancelled() {
        return Err(Error::Cancelled(Output::empty()));
    }
    if policy.timeout.is_zero()
        || policy.stdout_bytes > 64 * 1024 * 1024
        || policy.stderr_bytes > 16 * 1024 * 1024
        || policy.termination_grace > Duration::from_secs(5)
    {
        return Err(Error::InvalidPolicy);
    }
    let mut command = Command::new(executable);
    command
        .current_dir(directory)
        .args(arguments)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    for (name, _) in std::env::vars_os() {
        if environment
            .remove_prefixes
            .iter()
            .any(|prefix| name.as_bytes().starts_with(prefix.as_bytes()))
        {
            command.env_remove(name);
        }
    }
    command.envs(environment.set.iter().map(|(key, value)| (key, value)));
    #[cfg(target_os = "linux")]
    host::configure_local_command(&mut command, domain == Domain::Bundled)?;
    if parent_loss == ParentLoss::Terminate {
        let parent = unsafe { libc::getpid() };
        // Nur libc nach fork; die zweite Parentprüfung schließt das Fenster vor prctl.
        unsafe {
            command.pre_exec(move || {
                if libc::getppid() != parent {
                    return Err(io::Error::from_raw_os_error(libc::ECHILD));
                }
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    return Err(io::Error::from_raw_os_error(libc::ECHILD));
                }
                Ok(())
            });
        }
    }
    let child = command.spawn().map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::Unavailable
        } else {
            Error::Launch(error.to_string())
        }
    })?;
    let pid = i32::try_from(child.id()).map_err(|_| Error::Launch("invalid child PID".into()))?;
    let mut owned = OwnedChild {
        child,
        pid,
        reaped: false,
    };
    let stdout = unsafe {
        File::from_raw_fd(
            owned
                .child
                .stdout
                .take()
                .expect("piped stdout")
                .into_raw_fd(),
        )
    };
    let stderr = unsafe {
        File::from_raw_fd(
            owned
                .child
                .stderr
                .take()
                .expect("piped stderr")
                .into_raw_fd(),
        )
    };
    let mut stdin = owned
        .child
        .stdin
        .take()
        .map(|pipe| unsafe { File::from_raw_fd(pipe.into_raw_fd()) });
    if let Some(pipe) = &stdin {
        nonblocking(pipe).map_err(|error| Error::Capture {
            message: error.to_string(),
            output: Output::empty(),
        })?;
    }
    let input = input.unwrap_or(&[]);
    let mut written = 0usize;
    nonblocking(&stdout)
        .and_then(|()| nonblocking(&stderr))
        .map_err(|error| Error::Capture {
            message: error.to_string(),
            output: Output::empty(),
        })?;
    let mut stdout = Capture {
        pipe: Some(stdout),
        bytes: Vec::new(),
        limit: policy.stdout_bytes,
        exceeded: false,
    };
    let mut stderr = Capture {
        pipe: Some(stderr),
        bytes: Vec::new(),
        limit: policy.stderr_bytes,
        exceeded: false,
    };
    let started = Instant::now();
    let mut leader_exited_at = None;
    let mut stop = None;
    let mut capture_error = None;
    let mut terminated_at = None;
    let mut killed = false;
    loop {
        if let Some(pipe) = &mut stdin {
            for _ in 0..16 {
                if written == input.len() {
                    stdin = None;
                    break;
                }
                let end = (written + 8192).min(input.len());
                match pipe.write(&input[written..end]) {
                    Ok(0) => {
                        capture_error = Some("child stdin made no progress".into());
                        stop.get_or_insert(Stop::Capture);
                        stdin = None;
                        break;
                    }
                    Ok(n) => written += n,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        capture_error = Some(format!("child stdin: {error}"));
                        stop.get_or_insert(Stop::Capture);
                        stdin = None;
                        break;
                    }
                }
            }
        }
        let stderr_start = stderr.bytes.len();
        for capture in [&mut stdout, &mut stderr] {
            if let Err(error) = capture.drain() {
                capture_error = Some(error.to_string());
                capture.pipe = None;
                stop.get_or_insert(Stop::Capture);
            }
        }
        if let Some(observer) = stderr_observer.as_mut() {
            if stderr.bytes.len() > stderr_start {
                observer(&stderr.bytes[stderr_start..]);
            }
        }
        if cancellation.is_cancelled() {
            stop.get_or_insert(Stop::Cancelled);
        }
        if started.elapsed() >= policy.timeout {
            stop.get_or_insert(Stop::Timeout);
        }
        if stdout.exceeded || stderr.exceeded {
            stop.get_or_insert(Stop::Output);
        }
        let exited = match owned.exited() {
            Ok(value) => value,
            Err(error) => {
                capture_error = Some(error.to_string());
                stop.get_or_insert(Stop::Capture);
                false
            }
        };
        if exited && written < input.len() {
            capture_error.get_or_insert_with(|| "child exited before complete stdin".into());
            stop.get_or_insert(Stop::Capture);
            stdin = None;
        }
        if exited {
            leader_exited_at.get_or_insert_with(Instant::now);
        }
        if let Some(exited_at) = leader_exited_at {
            if stdout.pipe.is_none() && stderr.pipe.is_none() && stop.is_none() {
                break;
            }
            // Nach Elternende noch offene Pipes gehören verbliebenen Kindern.
            if exited_at.elapsed() >= Duration::from_millis(250) && stop.is_none() {
                capture_error = Some("child kept output pipes open after Git exited".into());
                stop = Some(Stop::Capture);
            }
        }
        if stop.is_some() {
            stdin = None;
            let terminated = *terminated_at.get_or_insert_with(|| {
                owned.signal(libc::SIGTERM);
                Instant::now()
            });
            if terminated.elapsed() >= policy.termination_grace && !killed {
                owned.signal(libc::SIGKILL);
                killed = true;
            }
            if killed && exited && stdout.pipe.is_none() && stderr.pipe.is_none() {
                break;
            }
            // Entkommene Kinder dürfen keine unbegrenzte Pipe-Wartezeit erzwingen.
            if killed
                && terminated.elapsed() >= policy.termination_grace + Duration::from_millis(250)
            {
                break;
            }
        }
        thread::sleep(Duration::from_millis(2));
    }
    // Letzte Gruppensignale vor wait(): Danach kann die Gruppen-ID neu vergeben werden.
    if !killed {
        owned.signal(libc::SIGKILL);
    }
    let status = owned.reap().map_err(|error| Error::Capture {
        message: error.to_string(),
        output: Output::empty(),
    })?;
    let output = Output {
        exit_code: status.code(),
        signal: status.signal(),
        stdout: stdout.bytes,
        stderr: stderr.bytes,
        stdout_truncated: stdout.exceeded,
        stderr_truncated: stderr.exceeded,
    };
    match stop {
        None => Ok(output),
        Some(Stop::Cancelled) => Err(Error::Cancelled(output)),
        Some(Stop::Timeout) => Err(Error::TimedOut(output)),
        Some(Stop::Output) => Err(Error::OutputLimit(output)),
        Some(Stop::Capture) => Err(Error::Capture {
            message: capture_error.unwrap_or_default(),
            output,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::{ffi::OsStringExt, fs::PermissionsExt},
        sync::Arc,
    };
    use tempfile::TempDir;

    fn helper(body: &str) -> (TempDir, std::path::PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("helper.py");
        fs::write(&path, format!("#!/usr/bin/python3\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        (directory, path)
    }
    fn run_helper(
        script: &Path,
        directory: &Path,
        arguments: &[OsString],
        policy: Policy,
        cancellation: &Cancellation,
    ) -> Result<Output, Error> {
        let mut all = vec![script.as_os_str().to_owned()];
        all.extend_from_slice(arguments);
        super::run(
            Path::new("/usr/bin/python3"),
            directory,
            &all,
            policy,
            cancellation,
            &Environment {
                remove_prefixes: vec!["GIT_".into()],
                set: vec![
                    ("GIT_TERMINAL_PROMPT".into(), "0".into()),
                    ("GIT_LITERAL_PATHSPECS".into(), "1".into()),
                    ("GIT_EDITOR".into(), "/usr/bin/false".into()),
                ],
            },
        )
    }
    fn policy() -> Policy {
        Policy {
            timeout: Duration::from_secs(3),
            termination_grace: Duration::from_millis(20),
            stdout_bytes: 3 * 1024 * 1024,
            stderr_bytes: 3 * 1024 * 1024,
        }
    }
    fn no_live_process(pid: i32) -> bool {
        match fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => stat
                .rsplit_once(')')
                .is_some_and(|(_, rest)| rest.starts_with(" Z") || rest.starts_with(" X")),
            Err(_) => true,
        }
    }
    fn assert_dead(pid: i32) {
        let deadline = Instant::now() + Duration::from_secs(1);
        while !no_live_process(pid) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(no_live_process(pid), "owned process {pid} still running");
    }
    #[test]
    fn exact_bytes_arguments_stdin_and_environment_without_shell() {
        let (directory, executable) = helper("import os,sys\nassert sys.stdin.buffer.read() == b''\nassert os.environ['GIT_TERMINAL_PROMPT'] == '0'\nassert os.environ['GIT_LITERAL_PATHSPECS'] == '1'\nassert os.environ['GIT_EDITOR'] == '/usr/bin/false'\nsys.stdout.buffer.write(os.fsencode(sys.argv[1]))\nsys.stderr.buffer.write(bytes([0,255,10]))");
        let argument = OsString::from_vec(b"literal\n;$(unexecuted)\xff".to_vec());
        let result = run_helper(
            &executable,
            directory.path(),
            &[argument],
            policy(),
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(result.stdout, b"literal\n;$(unexecuted)\xff");
        assert_eq!(result.stderr, [0, 255, 10]);
        assert!(result.success());
    }
    #[test]
    fn simultaneous_full_pipes_do_not_deadlock() {
        let (directory, executable) = helper(
            "import os\nfor _ in range(256):\n os.write(1,b'o'*8192)\n os.write(2,b'e'*8192)",
        );
        let result = run_helper(
            &executable,
            directory.path(),
            &[],
            policy(),
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(result.stdout, vec![b'o'; 2 * 1024 * 1024]);
        assert_eq!(result.stderr, vec![b'e'; 2 * 1024 * 1024]);
    }
    #[test]
    fn excess_output_is_bounded_and_process_is_stopped() {
        let (directory, executable) =
            helper("import os\nwhile True:\n os.write(1,b'x'*8192)\n os.write(2,b'y'*8192)");
        let policy = Policy {
            stdout_bytes: 1024,
            stderr_bytes: 512,
            ..policy()
        };
        let started = Instant::now();
        match run_helper(
            &executable,
            directory.path(),
            &[],
            policy,
            &Cancellation::default(),
        ) {
            Err(Error::OutputLimit(result)) => {
                assert_eq!(result.stdout, vec![b'x'; 1024]);
                assert!(result.stdout_truncated);
                assert!(result.stderr.len() <= 512);
            }
            result => panic!("{result:?}"),
        }
        assert!(started.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn timeout_kills_term_resistant_parent_and_child() {
        let (directory, executable) = helper("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid:\n open('pids','w').write(str(os.getpid())+' '+str(pid))\nwhile True: time.sleep(1)");
        let policy = Policy {
            timeout: Duration::from_millis(100),
            ..policy()
        };
        assert!(matches!(
            run_helper(
                &executable,
                directory.path(),
                &[],
                policy,
                &Cancellation::default()
            ),
            Err(Error::TimedOut(_))
        ));
        let pids = fs::read_to_string(directory.path().join("pids")).unwrap();
        for pid in pids.split_whitespace() {
            assert_dead(pid.parse().unwrap());
        }
    }
    #[test]
    fn cancellation_kills_only_its_owned_process_group() {
        let (directory, executable) = helper("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid: open('pids','w').write(str(os.getpid())+' '+str(pid))\nwhile True: time.sleep(1)");
        let mut unrelated = Command::new("/usr/bin/python3")
            .args(["-c", "import time; time.sleep(30)"])
            .process_group(0)
            .spawn()
            .unwrap();
        let cancel = Cancellation::default();
        let path = Arc::new(directory.path().to_owned());
        let worker_path = path.clone();
        let worker_cancel = cancel.clone();
        let worker = thread::spawn(move || {
            run_helper(&executable, &worker_path, &[], policy(), &worker_cancel)
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        while !path.join("pids").exists() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        cancel.cancel();
        let outcome = worker.join().unwrap();
        let unrelated_still_running = unrelated.try_wait().unwrap().is_none();
        unrelated.kill().unwrap();
        unrelated.wait().unwrap();
        assert!(unrelated_still_running);
        assert!(matches!(outcome, Err(Error::Cancelled(_))));
        for pid in fs::read_to_string(path.join("pids"))
            .unwrap()
            .split_whitespace()
        {
            assert_dead(pid.parse().unwrap());
        }
        // Ein späterer Abbruch enthält keine PID und kann nichts mehr signalisieren.
        cancel.cancel();
    }
    #[test]
    fn parent_exit_does_not_leave_pipe_holding_child_alive() {
        let (directory, executable) = helper("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid:\n open('pid','w').write(str(pid))\n os._exit(0)\nwhile True: time.sleep(1)");
        let result = run_helper(
            &executable,
            directory.path(),
            &[],
            policy(),
            &Cancellation::default(),
        );
        assert!(matches!(result, Err(Error::Capture { .. })), "{result:?}");
        assert_dead(
            fs::read_to_string(directory.path().join("pid"))
                .unwrap()
                .parse()
                .unwrap(),
        );
    }
    #[test]
    fn closed_pipe_child_is_cleaned_before_leader_is_reaped() {
        let (directory, executable) = helper("import os,time\npid=os.fork()\nif pid:\n open('pid','w').write(str(pid))\n os._exit(0)\nos.close(1)\nos.close(2)\nwhile True: time.sleep(1)");
        assert!(run_helper(
            &executable,
            directory.path(),
            &[],
            policy(),
            &Cancellation::default()
        )
        .unwrap()
        .success());
        assert_dead(
            fs::read_to_string(directory.path().join("pid"))
                .unwrap()
                .parse()
                .unwrap(),
        );
    }
    #[test]
    fn precancelled_call_does_not_launch() {
        let (directory, executable) = helper("open('launched','w').write('bad')");
        let cancel = Cancellation::default();
        cancel.cancel();
        assert!(matches!(
            run_helper(&executable, directory.path(), &[], policy(), &cancel),
            Err(Error::Cancelled(_))
        ));
        assert!(!directory.path().join("launched").exists());
    }
    fn input_helper(
        script: &Path,
        directory: &Path,
        input: &[u8],
        policy: Policy,
        cancel: &Cancellation,
    ) -> Result<Output, Error> {
        run_with_input(
            Path::new("/usr/bin/python3"),
            directory,
            &[script.as_os_str().to_owned()],
            input,
            policy,
            cancel,
            &Environment::default(),
        )
    }
    #[test]
    fn bounded_input_is_complete_and_duplex_without_deadlock() {
        let (dir,script)=helper("import os,sys,hashlib\nos.write(2,b'e'*100000)\ndata=sys.stdin.buffer.read()\nsys.stdout.buffer.write(hashlib.sha256(data).hexdigest().encode())");
        let input = vec![b'x'; 1024 * 1024];
        let out = input_helper(
            &script,
            dir.path(),
            &input,
            policy(),
            &Cancellation::default(),
        )
        .unwrap();
        assert!(out.success());
        assert_eq!(
            out.stdout,
            b"8f990ba0b577b51cf009ea049368c16bbda1b21e1b93be07a824758bb253c39b"
        );
        assert_eq!(out.stderr.len(), 100000);
        let (dir, script) = helper("import sys\nassert sys.stdin.buffer.read()==b''");
        assert!(
            input_helper(&script, dir.path(), b"", policy(), &Cancellation::default())
                .unwrap()
                .success()
        );
        assert!(matches!(
            input_helper(
                &script,
                dir.path(),
                &vec![0; MAX_INPUT_BYTES + 1],
                policy(),
                &Cancellation::default()
            ),
            Err(Error::InvalidPolicy)
        ));
    }
    #[test]
    fn early_closed_stdin_is_controlled_and_reaps_children() {
        let (dir,script)=helper("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid: open('pids','w').write(str(os.getpid())+' '+str(pid))\nos.close(0)\nwhile True: time.sleep(1)");
        let result = input_helper(
            &script,
            dir.path(),
            &vec![b'x'; 1024 * 1024],
            policy(),
            &Cancellation::default(),
        );
        assert!(matches!(result, Err(Error::Capture { .. })), "{result:?}");
        for pid in fs::read_to_string(dir.path().join("pids"))
            .unwrap()
            .split_whitespace()
        {
            assert_dead(pid.parse().unwrap());
        }
    }
    #[test]
    fn nonreading_stdin_obeys_deadline_and_cancellation_without_writer_join() {
        for cancel_case in [false, true] {
            let (dir,script)=helper("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid: open('pids','w').write(str(os.getpid())+' '+str(pid))\nwhile True: time.sleep(1)");
            let cancel = Cancellation::default();
            let worker_cancel = cancel.clone();
            let path = dir.path().to_owned();
            let started = Instant::now();
            let worker = thread::spawn(move || {
                input_helper(
                    &script,
                    &path,
                    &vec![b'x'; MAX_INPUT_BYTES],
                    Policy {
                        timeout: Duration::from_millis(400),
                        ..policy()
                    },
                    &worker_cancel,
                )
            });
            let deadline = Instant::now() + Duration::from_secs(2);
            while !dir.path().join("pids").exists() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(2));
            }
            if cancel_case {
                cancel.cancel();
            }
            let out = worker.join().unwrap();
            if cancel_case {
                assert!(matches!(out, Err(Error::Cancelled(_))), "{out:?}");
            } else {
                assert!(matches!(out, Err(Error::TimedOut(_))), "{out:?}");
            }
            assert!(started.elapsed() < Duration::from_secs(2));
            for pid in fs::read_to_string(dir.path().join("pids"))
                .unwrap()
                .split_whitespace()
            {
                assert_dead(pid.parse().unwrap());
            }
        }
    }
    #[test]
    fn isolated_document_input_keeps_bytes_beyond_host_channel_limit() {
        let (directory, executable) = helper("import sys\ndata=sys.stdin.buffer.read()\nassert len(data)==9*1024*1024\nassert data==b'q'*len(data)\nprint('complete')\n");
        let output = run_with_input_in(
            Domain::Isolated,
            &executable,
            directory.path(),
            &[],
            &vec![b'q'; 9 * 1024 * 1024],
            Policy {
                timeout: Duration::from_secs(5),
                stdout_bytes: 64,
                stderr_bytes: 1024,
                ..Policy::default()
            },
            &Cancellation::default(),
            &Environment::default(),
        )
        .unwrap();
        assert!(output.success());
        assert_eq!(output.stdout, b"complete\n");
    }
}

#[cfg(test)]
mod observer_tests {
    use super::*;
    #[test]
    fn stderr_observation_is_live_exact_and_bounded() {
        let root = tempfile::tempdir().unwrap();
        let marker = root.path().join("continue");
        let script = "import os,time,sys\nos.write(2,b'caf\\xc3')\ntime.sleep(.02)\nos.write(2,b'\\xa9: progress\\n')\nwhile not os.path.exists(sys.argv[1]): time.sleep(.002)\nos.write(2,b'x'*10000)";
        let mut seen = Vec::new();
        let output = run_with_stderr(
            Path::new("/usr/bin/python3"),
            root.path(),
            &["-c".into(), script.into(), marker.as_os_str().into()],
            Policy {
                stderr_bytes: 64,
                timeout: Duration::from_secs(2),
                ..Policy::default()
            },
            &Cancellation::default(),
            &Environment::default(),
            ParentLoss::Unchanged,
            &mut |bytes| {
                seen.extend_from_slice(bytes);
                if seen.ends_with(b"progress\n") {
                    std::fs::write(&marker, "continue").unwrap();
                }
            },
        );
        let Err(Error::OutputLimit(output)) = output else {
            panic!("unexpected output: {output:?}")
        };
        assert!(marker.exists(), "observer ran before completion");
        assert_eq!(seen, output.stderr);
        assert_eq!(seen.len(), 64);
        assert!(std::str::from_utf8(&seen)
            .unwrap()
            .starts_with("café: progress\n"));
    }


}
