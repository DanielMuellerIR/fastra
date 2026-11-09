//! Ein begrenzter Request je Verbindung; UID-Prüfung ersetzt keine Netzwerkfreigabe.
use fastra_core::local_control::*;
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};
mod native_package;
pub const SYSTEM_APPLICATION_ID: &str = "org.fastra.Fastra.Development";
pub const NATIVE_APPLICATION_ID: &str = "org.fastra.Fastra.NativeCandidate";
pub fn application_id() -> Result<&'static str> {
    Ok(match service_target()? {
        ServiceTarget::System => SYSTEM_APPLICATION_ID,
        ServiceTarget::Native => NATIVE_APPLICATION_ID,
    })
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServiceTarget {
    System,
    Native,
}
/// CLI-Rolle: ein GUI-Runtimemarker darf keinen Default-CLI-Aufruf umleiten.
pub fn service_target() -> Result<ServiceTarget> {
    if std::env::var_os("FASTRA_INTERNAL_HOST_FD").is_some()
        || std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some()
        || std::env::var_os("FASTRA_NATIVE_SHADOW_MANIFEST").is_some()
    {
        return Err(err());
    }
    match std::env::var_os("FASTRA_INTERNAL_NATIVE_SERVICE") {
        None => Ok(ServiceTarget::System),
        Some(v) if v == "1" => Ok(ServiceTarget::Native),
        Some(_) => Err(err()),
    }
}
fn gui_target() -> Result<ServiceTarget> {
    if std::env::var_os("FASTRA_INTERNAL_NATIVE_SERVICE").is_some() {
        return Err(err());
    }
    match std::env::var_os("FASTRA_NATIVE_RUNTIME") {
        None => Ok(ServiceTarget::System),
        Some(v) if v == "1" => {
            crate::initialize_runtime_policy().map_err(|_| err())?;
            Ok(ServiceTarget::Native)
        }
        Some(_) => Err(err()),
    }
}
pub fn native_launcher(expected_name: &str) -> Result<PathBuf> {
    if service_target()? != ServiceTarget::Native {
        return Err(err());
    }
    native_package::launcher(expected_name)
}
fn err() -> Failure {
    Failure::new("delivery")
}
fn valid_directory(path: &Path) -> Result<()> {
    let m = std::fs::symlink_metadata(path).map_err(|_| err())?;
    if !path.is_absolute()
        || !m.is_dir()
        || m.uid() != unsafe { libc::getuid() }
        || m.permissions().mode() & 0o077 != 0
    {
        Err(err())
    } else {
        Ok(())
    }
}
pub fn runtime_directory() -> Result<PathBuf> {
    let root = if let Some(path) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(path)
    } else {
        let path = PathBuf::from(format!("/tmp/fastra-control-{}", unsafe { libc::getuid() }));
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(err()),
        }
        path
    };
    valid_directory(&root)?;
    Ok(root)
}
fn endpoint_for(target: ServiceTarget) -> Result<PathBuf> {
    let id = match target {
        ServiceTarget::System => SYSTEM_APPLICATION_ID,
        ServiceTarget::Native => NATIVE_APPLICATION_ID,
    };
    let path = runtime_directory()?.join(format!("{id}.control.v1.sock"));
    if path.as_os_str().as_encoded_bytes().len() >= 108 {
        return Err(err());
    }
    Ok(path)
}
/// GUI-Server: ausschließlich die validierte GUI-Rolle bestimmt das Ziel.
pub fn endpoint() -> Result<PathBuf> {
    endpoint_for(gui_target()?)
}
pub fn cli_endpoint() -> Result<PathBuf> {
    endpoint_for(service_target()?)
}

fn connect(path: &Path, deadline: Instant) -> io::Result<UnixStream> {
    use std::os::{fd::FromRawFd, unix::ffi::OsStrExt};
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "socket path"));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (a, b) in address.sun_path.iter_mut().zip(bytes) {
        *a = *b as libc::c_char;
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    loop {
        if Instant::now() >= deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "connect deadline"));
        }
        let result = unsafe {
            libc::connect(
                fd,
                (&address as *const libc::sockaddr_un).cast(),
                std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
            )
        };
        if result == 0 {
            stream.set_nonblocking(false)?;
            return Ok(stream);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EISCONN) => {
                stream.set_nonblocking(false)?;
                return Ok(stream);
            }
            Some(libc::EAGAIN | libc::EINPROGRESS | libc::EALREADY | libc::EINTR) => {
                thread::sleep(Duration::from_millis(10))
            }
            _ => return Err(error),
        }
    }
}
fn peer(stream: &UnixStream) -> Result<()> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut size,
        )
    };
    if result != 0 || credentials.uid != unsafe { libc::getuid() } {
        return Err(err());
    }
    Ok(())
}
fn transfer(
    stream: &mut UnixStream,
    bytes: &mut [u8],
    write: bool,
    deadline: Instant,
    stop: &AtomicBool,
) -> Result<()> {
    let mut position = 0;
    while position < bytes.len() {
        if stop.load(Ordering::Acquire) || Instant::now() >= deadline {
            return Err(err());
        }
        let timeout = deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(50))
            .max(Duration::from_micros(1));
        stream.set_read_timeout(Some(timeout)).map_err(|_| err())?;
        stream.set_write_timeout(Some(timeout)).map_err(|_| err())?;
        let value = if write {
            stream.write(&bytes[position..])
        } else {
            stream.read(&mut bytes[position..])
        };
        match value {
            Ok(0) => return Err(err()),
            Ok(n) => position += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(_) => return Err(err()),
        }
    }
    Ok(())
}
pub fn read_frame(
    stream: &mut UnixStream,
    limit: usize,
    deadline: Instant,
    stop: &AtomicBool,
) -> Result<Vec<u8>> {
    let mut header = [0u8; 4];
    transfer(stream, &mut header, false, deadline, stop)?;
    let count = u32::from_be_bytes(header) as usize;
    if count == 0 || count > limit {
        return Err(Failure::new("invalidRequest"));
    }
    let mut bytes = vec![0; count];
    transfer(stream, &mut bytes, false, deadline, stop)?;
    Ok(bytes)
}
pub fn write_frame(
    stream: &mut UnixStream,
    bytes: &[u8],
    deadline: Instant,
    stop: &AtomicBool,
) -> Result<()> {
    let mut header = (bytes.len() as u32).to_be_bytes();
    transfer(stream, &mut header, true, deadline, stop)?;
    transfer(stream, &mut bytes.to_vec(), true, deadline, stop)
}
pub fn encode_reply(reply: &Reply) -> Vec<u8> {
    struct Bounded(Vec<u8>);
    impl Write for Bounded {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            if b.len() > MAX_REPLY - self.0.len() {
                return Err(io::Error::other("reply limit"));
            }
            self.0.extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut out = Bounded(Vec::new());
    if serde_json::to_writer(&mut out, reply).is_err() {
        serde_json::to_vec(&Reply::failure(
            reply.runtime_id.clone(),
            Failure::new("capacity"),
        ))
        .unwrap()
    } else {
        out.0
    }
}
pub fn request(path: &Path, bytes: &[u8], deadline: Instant) -> Result<Reply> {
    if bytes.len() > MAX_REQUEST {
        return Err(Failure::new("invalidRequest"));
    }
    let mut stream = connect(path, deadline).map_err(|_| err())?;
    peer(&stream)?;
    let stop = AtomicBool::new(false);
    write_frame(&mut stream, bytes, deadline, &stop)?;
    let raw = read_frame(&mut stream, MAX_REPLY, deadline, &stop)?;
    serde_json::from_slice(&raw).map_err(|_| err())
}
pub struct Delivery {
    pub request: Vec<u8>,
    pub reply: mpsc::SyncSender<Reply>,
    pub deadline: Instant,
}
pub struct Server {
    stop: Arc<AtomicBool>,
    path: PathBuf,
    identity: (u64, u64),
    _lock: File,
}
impl Server {
    pub fn start(path: &Path) -> Result<(Self, mpsc::Receiver<Delivery>)> {
        valid_directory(path.parent().ok_or_else(err)?)?;
        let lock_path = path.with_extension("lock");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(lock_path)
            .map_err(|_| err())?;
        let m = lock.metadata().map_err(|_| err())?;
        if !m.is_file()
            || m.uid() != unsafe { libc::getuid() }
            || m.nlink() != 1
            || m.permissions().mode() & 0o077 != 0
            || unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
        {
            return Err(err());
        }
        if let Ok(meta) = std::fs::symlink_metadata(path) {
            if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::getuid() } {
                return Err(err());
            }
            match connect(path, Instant::now() + Duration::from_millis(100)) {
                Ok(_) => return Err(err()),
                Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => {
                    std::fs::remove_file(path).map_err(|_| err())?
                }
                Err(_) => return Err(err()),
            }
        }
        let listener = UnixListener::bind(path).map_err(|_| err())?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| err())?;
        listener.set_nonblocking(true).map_err(|_| err())?;
        let meta = std::fs::symlink_metadata(path).map_err(|_| err())?;
        let stop = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = mpsc::sync_channel::<Delivery>(16);
        // Vier feste Worker begrenzen auch langsame oder unvollständige Verbindungen.
        for _ in 0..4 {
            let listener = listener.try_clone().map_err(|_| err())?;
            let stop = stop.clone();
            let sender = sender.clone();
            thread::spawn(move || {
                while !stop.load(Ordering::Acquire) {
                    let (mut stream, _) = match listener.accept() {
                        Ok(pair) => pair,
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10));
                            continue;
                        }
                        Err(_) => break,
                    };
                    let deadline = Instant::now() + Duration::from_secs(10);
                    if peer(&stream).is_err() {
                        continue;
                    }
                    let response = match read_frame(&mut stream, MAX_REQUEST, deadline, &stop) {
                        Ok(request) => {
                            let (tx, rx) = mpsc::sync_channel(1);
                            if sender
                                .try_send(Delivery {
                                    request,
                                    reply: tx,
                                    deadline,
                                })
                                .is_err()
                            {
                                Reply::failure(None, Failure::new("capacity"))
                            } else {
                                loop {
                                    if stop.load(Ordering::Acquire) || Instant::now() >= deadline {
                                        break Reply::failure(None, err());
                                    }
                                    match rx.recv_timeout(Duration::from_millis(20)) {
                                        Ok(reply) => break reply,
                                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                                        Err(_) => break Reply::failure(None, err()),
                                    }
                                }
                            }
                        }
                        Err(error) => Reply::failure(None, error),
                    };
                    let _ = write_frame(&mut stream, &encode_reply(&response), deadline, &stop);
                }
            });
        }
        Ok((
            Self {
                stop,
                path: path.into(),
                identity: (meta.dev(), meta.ino()),
                _lock: lock,
            },
            receiver,
        ))
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if std::fs::symlink_metadata(&self.path).is_ok_and(|m| (m.dev(), m.ino()) == self.identity)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}
