//! JSON-Helfer ohne GTK und ohne frei konfigurierbare Programmausführung.
use fastra_core::local_control::*;
use fastra_io::local_control::{now, transport};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn invalid() -> Failure {
    Failure::new("invalidRequest")
}
fn input(path: &std::ffi::OsStr, deadline: Instant) -> Result<Vec<u8>> {
    let file = if path == "-" {
        let fd = unsafe { libc::fcntl(libc::STDIN_FILENO, libc::F_DUPFD_CLOEXEC, 3) };
        if fd < 0 {
            return Err(invalid());
        }
        use std::os::fd::FromRawFd;
        unsafe { File::from_raw_fd(fd) }
    } else {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| invalid())?;
        if !file.metadata().map_err(|_| invalid())?.is_file() {
            return Err(invalid());
        }
        file
    };
    let mut file = file;
    let mut bytes = Vec::new();
    let mut block = [0u8; 4096];
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| Failure::new("delivery"))?;
        let mut poll = libc::pollfd {
            fd: file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe {
            libc::poll(
                &mut poll,
                1,
                remaining.as_millis().min(i32::MAX as u128) as i32,
            )
        };
        if result == 0 {
            return Err(Failure::new("delivery"));
        }
        if result < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(invalid());
        }
        let count = block.len().min(MAX_REQUEST + 1 - bytes.len());
        let n = file.read(&mut block[..count]).map_err(|_| invalid())?;
        if n == 0 {
            return Ok(bytes);
        }
        bytes.extend_from_slice(&block[..n]);
        if bytes.len() > MAX_REQUEST {
            return Err(invalid());
        }
    }
}
fn execute() -> Result<Reply> {
    transport::service_target()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut args: Vec<_> = std::env::args_os().skip(1).collect();
    let no_launch = args.first().is_some_and(|s| s == "--no-launch");
    if no_launch {
        args.remove(0);
    }
    if args == ["--capabilities", "--json"] {
        let mut reply = Reply::new(None);
        reply.capabilities = Some(Capabilities::default());
        return Ok(reply);
    }
    if args.len() != 2 || args[0] != "--request" {
        return Err(invalid());
    }
    let bytes = input(&args[1], deadline)?;
    let request = Request::decode(&bytes)?;
    request.validate(now(), true)?;
    let native = if transport::service_target()? == transport::ServiceTarget::Native {
        Some(transport::native_launcher("fastra-control")?)
    } else {
        None
    };
    let endpoint = transport::cli_endpoint()?;
    let mut launched = false;
    loop {
        if Instant::now() >= deadline {
            return Err(Failure::new("delivery"));
        }
        match transport::request(&endpoint, &bytes, deadline) {
            Ok(reply) => return Ok(reply),
            Err(_) if no_launch => return Err(Failure::new("delivery")),
            Err(_) => {}
        }
        if !launched {
            let application: PathBuf = if let Some(path) = &native {
                path.clone()
            } else {
                let executable = std::env::current_exe()
                    .and_then(std::fs::canonicalize)
                    .map_err(|_| Failure::new("delivery"))?;
                executable
                    .parent()
                    .ok_or_else(|| Failure::new("delivery"))?
                    .join("fastra-linux")
            };
            if !application.is_file() {
                return Err(Failure::new("delivery"));
            }
            let child = Command::new(application)
                .arg("--local-control-service")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| Failure::new("delivery"))?;
            std::thread::spawn(move || {
                let mut child = child;
                let _ = child.wait();
            });
            launched = true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}
fn main() {
    let reply = execute().unwrap_or_else(|e| Reply::failure(None, e));
    let mut bytes = transport::encode_reply(&reply);
    bytes.push(b'\n');
    let success = reply.error.is_none();
    let written = std::io::stdout().lock().write_all(&bytes).is_ok();
    std::process::exit(if success && written { 0 } else { 1 });
}
