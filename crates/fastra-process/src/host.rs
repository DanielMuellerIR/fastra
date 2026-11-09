//! Privater Hostkanal: ausschließlich geerbte FDs, keine öffentliche Socketadresse.
use super::*;
use std::{
    net::Shutdown,
    os::{
        fd::{OwnedFd, RawFd},
        unix::{ffi::OsStringExt, net::UnixStream},
    },
    sync::{Mutex, OnceLock},
};
const FD_ENV: &str = "FASTRA_INTERNAL_HOST_FD";
const MAX_REQUEST: usize = 12 * 1024 * 1024;
const MAX_RESPONSE: usize = 81 * 1024 * 1024;
const MAX_ACTIVE: usize = 4;
static CLIENT: OnceLock<Result<Option<UnixStream>, String>> = OnceLock::new();
thread_local! {
    static HOST_CHILD_MASK: std::cell::Cell<Option<libc::sigset_t>> = const { std::cell::Cell::new(None) };
}
fn io_error(e: io::Error) -> Error {
    Error::Capture {
        message: format!("private host channel: {e}"),
        output: Output::empty(),
    }
}
fn client() -> Result<Option<&'static UnixStream>, Error> {
    CLIENT
        .get_or_init(|| {
            let Some(value) = std::env::var_os(FD_ENV) else {
                return Ok(None);
            };
            let fd = value
                .to_str()
                .and_then(|s| s.parse::<i32>().ok())
                .filter(|f| *f >= 3)
                .ok_or("invalid private host descriptor")?;
            let mut kind = 0i32;
            let mut len = std::mem::size_of::<i32>() as libc::socklen_t;
            if unsafe {
                libc::getsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_TYPE,
                    &mut kind as *mut _ as *mut _,
                    &mut len,
                )
            } != 0
                || kind != libc::SOCK_STREAM
            {
                return Err("private host descriptor is not a stream socket".into());
            }
            let mut address: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
            let mut address_len = std::mem::size_of_val(&address) as libc::socklen_t;
            if unsafe { libc::getsockname(fd, &mut address as *mut _ as *mut _, &mut address_len) }
                != 0
                || address.ss_family as i32 != libc::AF_UNIX
            {
                return Err("private host descriptor is not a Unix socket".into());
            }
            if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err("cannot protect private host descriptor".into());
            }
            let stream = unsafe { UnixStream::from_raw_fd(fd) };
            stream
                .set_write_timeout(Some(Duration::from_millis(20)))
                .map_err(|_| "cannot bound private host sender")?;
            Ok(Some(stream))
        })
        .as_ref()
        .map(|s| s.as_ref())
        .map_err(|s| Error::Launch(s.clone()))
}
fn send_fd(socket: &UnixStream, fd: RawFd) -> io::Result<()> {
    // Ein Byte mit genau einem FD ist auf Linux eine einzelne SCM_RIGHTS-Zuordnung.
    // Antworten laufen ausschließlich über das dabei übergebene eigene Requestpaar.
    let deadline = Instant::now() + Duration::from_millis(250);
    let mut byte = 1u8;
    let mut iov = libc::iovec {
        iov_base: &mut byte as *mut _ as *mut _,
        iov_len: 1,
    };
    let mut control = [0usize; 8];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr() as *mut _;
    msg.msg_controllen = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as _) as usize };
    unsafe {
        let c = libc::CMSG_FIRSTHDR(&msg);
        (*c).cmsg_level = libc::SOL_SOCKET;
        (*c).cmsg_type = libc::SCM_RIGHTS;
        (*c).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as _) as usize;
        std::ptr::write_unaligned(libc::CMSG_DATA(c) as *mut RawFd, fd);
    }
    loop {
        if Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let n = unsafe { libc::sendmsg(socket.as_raw_fd(), &msg, libc::MSG_NOSIGNAL) };
        if n == 1 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}
fn recv_fd(socket: &UnixStream) -> io::Result<Option<OwnedFd>> {
    let mut byte = 0u8;
    let mut iov = libc::iovec {
        iov_base: &mut byte as *mut _ as *mut _,
        iov_len: 1,
    };
    let mut control = [0usize; 8];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr() as *mut _;
    msg.msg_controllen = std::mem::size_of_val(&control);
    let n = loop {
        let n = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut msg, libc::MSG_CMSG_CLOEXEC) };
        if n >= 0 {
            break n;
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    };
    if n == 0 {
        return Ok(None);
    }
    let mut received = Vec::new();
    unsafe {
        let mut c = libc::CMSG_FIRSTHDR(&msg);
        while !c.is_null() {
            if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                let bytes = (*c).cmsg_len.saturating_sub(libc::CMSG_LEN(0) as usize);
                for i in 0..bytes / std::mem::size_of::<RawFd>() {
                    received.push(OwnedFd::from_raw_fd(std::ptr::read_unaligned(
                        (libc::CMSG_DATA(c) as *const RawFd).add(i),
                    )));
                }
            }
            c = libc::CMSG_NXTHDR(&msg, c);
        }
    }
    if byte != 1 || msg.msg_flags & libc::MSG_CTRUNC != 0 || received.len() != 1 {
        return Err(io::Error::other("invalid private descriptor message"));
    }
    Ok(received.pop())
}
fn transfer(
    stream: &mut UnixStream,
    bytes: &[u8],
    deadline: Instant,
    cancel: Option<&Cancellation>,
) -> io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_millis(20)))?;
    let mut at = 0;
    while at < bytes.len() {
        if Instant::now() >= deadline || cancel.is_some_and(Cancellation::is_cancelled) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "host write stopped",
            ));
        }
        match stream.write(&bytes[at..]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => at += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn exact(
    stream: &mut UnixStream,
    bytes: &mut [u8],
    deadline: Instant,
    cancel: Option<&Cancellation>,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(20)))?;
    let mut at = 0;
    while at < bytes.len() {
        if Instant::now() >= deadline || cancel.is_some_and(Cancellation::is_cancelled) {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "host read stopped"));
        }
        match stream.read(&mut bytes[at..]) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => at += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn frame(
    stream: &mut UnixStream,
    tag: u8,
    bytes: &[u8],
    deadline: Instant,
    cancel: Option<&Cancellation>,
) -> io::Result<()> {
    transfer(stream, &[tag], deadline, cancel)?;
    transfer(
        stream,
        &(bytes.len() as u32).to_le_bytes(),
        deadline,
        cancel,
    )?;
    transfer(stream, bytes, deadline, cancel)
}
fn receive(
    stream: &mut UnixStream,
    max: usize,
    deadline: Instant,
    cancel: Option<&Cancellation>,
) -> io::Result<(u8, Vec<u8>)> {
    let mut head = [0; 5];
    exact(stream, &mut head, deadline, cancel)?;
    let n = u32::from_le_bytes(head[1..].try_into().unwrap()) as usize;
    if n > max {
        return Err(io::Error::other("host frame exceeds limit"));
    }
    let mut data = vec![0; n];
    exact(stream, &mut data, deadline, cancel)?;
    Ok((head[0], data))
}
fn exact_client(
    stream: &mut UnixStream,
    bytes: &mut [u8],
    deadline: Instant,
    cancel: &Cancellation,
    stopped: &mut Option<Instant>,
    grace: Duration,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(10)))?;
    let mut at = 0;
    while at < bytes.len() {
        if cancel.is_cancelled() && stopped.is_none() {
            transfer(
                stream,
                &[1],
                Instant::now() + Duration::from_millis(100),
                None,
            )?;
            *stopped = Some(Instant::now());
        }
        if Instant::now() >= deadline
            || stopped.is_some_and(|t| t.elapsed() > grace + Duration::from_secs(6))
        {
            return Err(io::ErrorKind::TimedOut.into());
        }
        match stream.read(&mut bytes[at..]) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => at += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn client_response(
    stream: &mut UnixStream,
    deadline: Instant,
    cancel: &Cancellation,
    stopped: &mut Option<Instant>,
    grace: Duration,
) -> io::Result<(u8, Vec<u8>)> {
    let mut h = [0; 5];
    exact_client(stream, &mut h, deadline, cancel, stopped, grace)?;
    let n = u32::from_le_bytes(h[1..].try_into().unwrap()) as usize;
    if n > MAX_RESPONSE || (h[0] == 2 && n > 128 * 1024) {
        return Err(io::Error::other("host response exceeds limit"));
    }
    let mut b = vec![0; n];
    exact_client(stream, &mut b, deadline, cancel, stopped, grace)?;
    Ok((h[0], b))
}
struct Encoder(Vec<u8>);
impl Encoder {
    fn write_u64(&mut self, n: u64) {
        self.0.extend(n.to_le_bytes())
    }
    fn write_bytes(&mut self, b: &[u8]) {
        self.write_u64(b.len() as u64);
        self.0.extend(b)
    }
    fn write_os(&mut self, s: &std::ffi::OsStr) {
        self.write_bytes(s.as_bytes())
    }
}
struct Decoder<'a>(&'a [u8]);
impl<'a> Decoder<'a> {
    fn read_u64(&mut self) -> io::Result<u64> {
        if self.0.len() < 8 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let n = u64::from_le_bytes(self.0[..8].try_into().unwrap());
        self.0 = &self.0[8..];
        Ok(n)
    }
    fn read_bytes(&mut self, max: usize) -> io::Result<Vec<u8>> {
        let n =
            usize::try_from(self.read_u64()?).map_err(|_| io::Error::other("length overflow"))?;
        if n > max || n > self.0.len() {
            return Err(io::Error::other("invalid host field length"));
        }
        let b = self.0[..n].to_vec();
        self.0 = &self.0[n..];
        Ok(b)
    }
    fn read_os(&mut self) -> io::Result<OsString> {
        let b = self.read_bytes(1024 * 1024)?;
        if b.contains(&0) {
            return Err(io::Error::other("NUL in host argument"));
        }
        Ok(OsString::from_vec(b))
    }
    fn finish(&self) -> io::Result<()> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(io::Error::other("trailing host fields"))
        }
    }
}
fn encode_output(result: Result<Output, Error>) -> Vec<u8> {
    let (tag, message, out) = match result {
        Ok(o) => (0, String::new(), o),
        Err(Error::Unavailable) => (1, String::new(), Output::empty()),
        Err(Error::Launch(m)) => (2, m, Output::empty()),
        Err(Error::InvalidPolicy) => (3, String::new(), Output::empty()),
        Err(Error::Cancelled(o)) => (4, String::new(), o),
        Err(Error::TimedOut(o)) => (5, String::new(), o),
        Err(Error::OutputLimit(o)) => (6, String::new(), o),
        Err(Error::Capture { message, output }) => (7, message, output),
    };
    let mut e = Encoder(vec![tag]);
    e.write_bytes(message.as_bytes());
    e.write_u64(out.exit_code.map_or(u64::MAX, |n| n as u64));
    e.write_u64(out.signal.map_or(u64::MAX, |n| n as u64));
    e.write_u64(out.stdout_truncated as u64);
    e.write_u64(out.stderr_truncated as u64);
    e.write_bytes(&out.stdout);
    e.write_bytes(&out.stderr);
    e.0
}
fn decode_output(bytes: &[u8]) -> io::Result<Result<Output, Error>> {
    let (&tag, rest) = bytes.split_first().ok_or(io::ErrorKind::UnexpectedEof)?;
    let mut d = Decoder(rest);
    let message = String::from_utf8(d.read_bytes(64 * 1024)?)
        .map_err(|_| io::Error::other("invalid host error"))?;
    let code = d.read_u64()?;
    let sig = d.read_u64()?;
    let o = Output {
        exit_code: (code != u64::MAX).then_some(code as i32),
        signal: (sig != u64::MAX).then_some(sig as i32),
        stdout_truncated: d.read_u64()? != 0,
        stderr_truncated: d.read_u64()? != 0,
        stdout: d.read_bytes(64 * 1024 * 1024)?,
        stderr: d.read_bytes(16 * 1024 * 1024)?,
    };
    d.finish()?;
    Ok(match tag {
        0 => Ok(o),
        1 => Err(Error::Unavailable),
        2 => Err(Error::Launch(message)),
        3 => Err(Error::InvalidPolicy),
        4 => Err(Error::Cancelled(o)),
        5 => Err(Error::TimedOut(o)),
        6 => Err(Error::OutputLimit(o)),
        7 => Err(Error::Capture { message, output: o }),
        _ => return Err(io::Error::other("invalid host result")),
    })
}
fn unsafe_delta(name: &std::ffi::OsStr) -> bool {
    let n = name.as_bytes();
    if n == FD_ENV.as_bytes() {
        return true;
    }
    [
        b"LD_".as_slice(),
        b"DYLD_",
        b"GTK_",
        b"GDK_",
        b"GIO_",
        b"GST_",
        b"WEBKIT_",
        b"GI_TYPELIB_",
    ]
    .iter()
    .any(|p| n.starts_with(p))
}
#[allow(clippy::too_many_arguments)]
pub(super) fn invoke(
    executable: &Path,
    directory: &Path,
    args: &[OsString],
    input: Option<&[u8]>,
    policy: Policy,
    cancel: &Cancellation,
    env: &Environment,
    parent: ParentLoss,
    observer: &mut Option<StderrObserver<'_>>,
) -> Option<Result<Output, Error>> {
    let channel = match client() {
        Ok(None) => return None,
        Ok(Some(c)) => c,
        Err(e) => return Some(Err(e)),
    };
    Some((|| {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled(Output::empty()));
        }
        if !directory.is_absolute()
            || args.len() > 4096
            || env.set.len() > 256
            || env.remove_prefixes.len() > 256
            || input.is_some_and(|v| v.len() > MAX_INPUT_BYTES)
            || policy.timeout.is_zero()
            || policy.timeout > Duration::from_secs(86400)
            || policy.termination_grace > Duration::from_secs(5)
            || policy.stdout_bytes > 64 * 1024 * 1024
            || policy.stderr_bytes > 16 * 1024 * 1024
            || env.set.iter().any(|(n, _)| unsafe_delta(n))
        {
            return Err(Error::InvalidPolicy);
        }
        let fields = std::iter::once(executable.as_os_str())
            .chain(std::iter::once(directory.as_os_str()))
            .chain(args.iter().map(OsString::as_os_str))
            .chain(env.remove_prefixes.iter().map(OsString::as_os_str))
            .chain(
                env.set
                    .iter()
                    .flat_map(|(n, v)| [n.as_os_str(), v.as_os_str()]),
            );
        let mut total = 128usize + (args.len() + env.remove_prefixes.len() + env.set.len() * 2) * 8;
        for field in fields {
            if field.as_bytes().len() > 1024 * 1024 || field.as_bytes().contains(&0) {
                return Err(Error::InvalidPolicy);
            }
            total = total
                .checked_add(field.as_bytes().len())
                .filter(|n| *n <= MAX_REQUEST)
                .ok_or(Error::InvalidPolicy)?;
        }
        if total
            .checked_add(input.map_or(0, |s| s.len()))
            .is_none_or(|n| n > MAX_REQUEST)
        {
            return Err(Error::InvalidPolicy);
        }
        let mut e = Encoder(b"FHS1".to_vec());
        e.write_os(executable.as_os_str());
        e.write_os(directory.as_os_str());
        e.write_u64(args.len() as u64);
        for a in args {
            e.write_os(a)
        }
        e.write_u64(policy.timeout.as_millis() as u64);
        e.write_u64(policy.termination_grace.as_millis() as u64);
        e.write_u64(policy.stdout_bytes as u64);
        e.write_u64(policy.stderr_bytes as u64);
        e.write_u64((parent == ParentLoss::Terminate) as u64);
        e.write_u64(input.is_some() as u64);
        e.write_bytes(input.unwrap_or(&[]));
        e.write_u64(env.remove_prefixes.len() as u64);
        for n in &env.remove_prefixes {
            e.write_os(n)
        }
        e.write_u64(env.set.len() as u64);
        for (n, v) in &env.set {
            e.write_os(n);
            e.write_os(v)
        }
        if e.0.len() > MAX_REQUEST {
            return Err(Error::InvalidPolicy);
        }
        let (mut stream, server) = UnixStream::pair().map_err(io_error)?;
        send_fd(channel, server.as_raw_fd()).map_err(io_error)?;
        drop(server);
        let deadline =
            Instant::now() + policy.timeout + policy.termination_grace + Duration::from_secs(2);
        if let Err(error) = frame(&mut stream, 1, &e.0, deadline, Some(cancel)) {
            let _ = stream.shutdown(Shutdown::Both);
            return Err(if cancel.is_cancelled() {
                Error::Cancelled(Output::empty())
            } else if Instant::now() >= deadline {
                Error::TimedOut(Output::empty())
            } else {
                io_error(error)
            });
        }
        let mut stopped = None;
        loop {
            let next = client_response(
                &mut stream,
                deadline,
                cancel,
                &mut stopped,
                policy.termination_grace,
            );
            match next {
                Ok((2, data)) => {
                    if let Some(f) = observer.as_mut() {
                        f(&data)
                    }
                }
                Ok((3, data)) => return decode_output(&data).map_err(io_error)?,
                Ok(_) => return Err(io_error(io::Error::other("invalid host response"))),
                Err(e) => {
                    let _ = stream.shutdown(Shutdown::Both);
                    return Err(if cancel.is_cancelled() {
                        Error::Cancelled(Output::empty())
                    } else if Instant::now() >= deadline {
                        Error::TimedOut(Output::empty())
                    } else {
                        io_error(e)
                    });
                }
            }
        }
    })())
}
struct Request {
    exe: std::path::PathBuf,
    cwd: std::path::PathBuf,
    args: Vec<OsString>,
    input: Option<Vec<u8>>,
    policy: Policy,
    env: Environment,
    parent: ParentLoss,
}
fn request(bytes: &[u8]) -> io::Result<Request> {
    if bytes.len() < 4 || &bytes[..4] != b"FHS1" {
        return Err(io::Error::other("host protocol version"));
    }
    let mut d = Decoder(&bytes[4..]);
    let exe = d.read_os()?.into();
    let cwd = std::path::PathBuf::from(d.read_os()?);
    if !cwd.is_absolute() {
        return Err(io::Error::other("host cwd must be absolute"));
    }
    let n = d.read_u64()?;
    if n > 4096 {
        return Err(io::Error::other("host argument count"));
    }
    let mut args = Vec::new();
    for _ in 0..n {
        args.push(d.read_os()?)
    }
    let timeout = d.read_u64()?;
    let grace = d.read_u64()?;
    let stdout = d.read_u64()?;
    let stderr = d.read_u64()?;
    let parent = if d.read_u64()? == 0 {
        ParentLoss::Unchanged
    } else {
        ParentLoss::Terminate
    };
    let has_input = d.read_u64()? != 0;
    let input = d.read_bytes(MAX_INPUT_BYTES)?;
    let policy = Policy {
        timeout: Duration::from_millis(timeout),
        termination_grace: Duration::from_millis(grace),
        stdout_bytes: stdout as usize,
        stderr_bytes: stderr as usize,
    };
    if timeout == 0
        || timeout > 86400000
        || grace > 5000
        || stdout > 64 * 1024 * 1024
        || stderr > 16 * 1024 * 1024
    {
        return Err(io::Error::other("host policy exceeds limit"));
    }
    let n = d.read_u64()?;
    if n > 256 {
        return Err(io::Error::other("host environment count"));
    }
    let mut env = Environment::default();
    for _ in 0..n {
        let key = d.read_os()?;
        env.remove_prefixes.push(key)
    }
    let n = d.read_u64()?;
    if n > 256 {
        return Err(io::Error::other("host environment count"));
    }
    for _ in 0..n {
        let key = d.read_os()?;
        let value = d.read_os()?;
        if key.is_empty() || key.as_bytes().contains(&b'=') || unsafe_delta(&key) {
            return Err(io::Error::other("invalid host environment delta"));
        }
        env.set.push((key, value))
    }
    d.finish()?;
    Ok(Request {
        exe,
        cwd,
        args,
        input: has_input.then_some(input),
        policy,
        env,
        parent,
    })
}
fn serve_request(mut stream: UnixStream, cancel: Cancellation, child_mask: libc::sigset_t) {
    HOST_CHILD_MASK.set(Some(child_mask));
    let received = receive(
        &mut stream,
        MAX_REQUEST,
        Instant::now() + Duration::from_secs(5),
        Some(&cancel),
    );
    if let Ok((4, ref bytes)) = received {
        let mut d = Decoder(bytes);
        let output = match d.read_os().and_then(|name| {
            d.finish()?;
            Ok(name)
        }) {
            Ok(name) => resolve_in_worker(&name, &cancel),
            Err(error) => Err(io_error(error)),
        };
        let _ = frame(
            &mut stream,
            3,
            &encode_output(output),
            Instant::now() + Duration::from_secs(1),
            None,
        );
        return;
    }
    let parsed = received.and_then(|(tag, b)| {
        if tag == 1 {
            request(&b)
        } else {
            Err(io::Error::other("invalid request frame"))
        }
    });
    let r = match parsed {
        Ok(r) => r,
        Err(e) => {
            let _ = frame(
                &mut stream,
                3,
                &encode_output(Err(io_error(e))),
                Instant::now() + Duration::from_secs(1),
                None,
            );
            return;
        }
    };
    let mut watch = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    let mut writer_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    let finish_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    let stop = cancel.clone();
    let watcher = thread::Builder::new()
        .name("fastra-host-cancel".into())
        .spawn(move || {
            let mut b = [0];
            loop {
                match watch.read(&mut b) {
                    Ok(_) => {
                        stop.cancel();
                        break;
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::TimedOut
                                | io::ErrorKind::WouldBlock
                                | io::ErrorKind::Interrupted
                        ) => {}
                    Err(_) => {
                        stop.cancel();
                        break;
                    }
                }
            }
        });
    let watcher = match watcher {
        Ok(w) => w,
        Err(_) => return,
    };
    let (tx, rx) = std::sync::mpsc::sync_channel::<(u8, Vec<u8>)>(8);
    let writer_cancel = cancel.clone();
    let transport_failed = Arc::new(AtomicBool::new(false));
    let writer_failed = transport_failed.clone();
    let writer = thread::Builder::new()
        .name("fastra-host-output".into())
        .spawn(move || {
            for (tag, b) in rx {
                if frame(
                    &mut writer_stream,
                    tag,
                    &b,
                    Instant::now() + Duration::from_secs(5),
                    None,
                )
                .is_err()
                {
                    writer_failed.store(true, Ordering::Release);
                    writer_cancel.cancel();
                    break;
                }
            }
        });
    let writer = match writer {
        Ok(w) => w,
        Err(_) => {
            let _ = finish_stream.shutdown(Shutdown::Both);
            let _ = watcher.join();
            return;
        }
    };
    let mut observed = |bytes: &[u8]| {
        if tx.try_send((2, bytes.to_vec())).is_err() {
            transport_failed.store(true, Ordering::Release);
            cancel.cancel();
        }
    };
    let result = super::run_local(
        Domain::Host,
        &r.exe,
        &r.cwd,
        &r.args,
        r.input.as_deref(),
        r.policy,
        &cancel,
        &r.env,
        r.parent,
        Some(&mut observed),
    );
    let result = if transport_failed.load(Ordering::Acquire) {
        match result {
            Ok(output) | Err(Error::Cancelled(output)) => Err(Error::Capture {
                message: "private host output transport stalled".into(),
                output,
            }),
            other => other,
        }
    } else {
        result
    };
    let _ = tx.send((3, encode_output(result)));
    drop(tx);
    let _ = writer.join();
    let _ = finish_stream.shutdown(Shutdown::Both);
    let _ = watcher.join();
}
/// Vererbt den Kanal ausschließlich an bewusst gebündelte interne Helfer.
pub(super) fn configure_local_command(command: &mut Command, inherit: bool) -> Result<(), Error> {
    // Auch ein noch nicht benutzter geerbter Kanal muss vor lokalem Exec CLOEXEC sein.
    let stream = client()?;
    // Der Owner wartet synchron auf Stoppsignale; Hosttools brauchen trotzdem ihre ursprüngliche Maske.
    if let Some(mask) = HOST_CHILD_MASK.get() {
        unsafe {
            command.pre_exec(move || {
                let code = libc::pthread_sigmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut());
                if code != 0 {
                    return Err(io::Error::from_raw_os_error(code));
                }
                Ok(())
            });
        }
    }
    command.env_remove(FD_ENV);
    if !inherit {
        return Ok(());
    }
    let Some(stream) = stream else {
        return Ok(());
    };
    let fd = stream.as_raw_fd();
    command.env(FD_ENV, "3");
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(fd, 3) < 0 || libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}
fn resolve_local(name: &std::ffi::OsStr) -> Option<std::path::PathBuf> {
    let path = Path::new(name);
    let candidates = if path.is_absolute() {
        vec![path.to_path_buf()]
    } else if name.as_bytes().contains(&b'/') {
        return None;
    } else {
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .map(|p| p.join(name))
            .collect()
    };
    candidates
        .into_iter()
        .find(|p| {
            p.is_file()
                && std::ffi::CString::new(p.as_os_str().as_bytes())
                    .is_ok_and(|p| unsafe { libc::access(p.as_ptr(), libc::X_OK) } == 0)
        })
        .and_then(|p| {
            if p.is_absolute() {
                Some(p)
            } else {
                std::env::current_dir().ok().map(|cwd| cwd.join(p))
            }
        })
}
fn resolve_in_worker(name: &std::ffi::OsStr, cancel: &Cancellation) -> Result<Output, Error> {
    let executable = std::env::current_exe().map_err(io_error)?;
    let directory = std::env::current_dir().map_err(io_error)?;
    let output = super::run_local(
        Domain::Host,
        &executable,
        &directory,
        &["--internal-resolve".into(), name.to_owned()],
        None,
        Policy {
            timeout: Duration::from_secs(2),
            stdout_bytes: 65536,
            stderr_bytes: 1024,
            ..Policy::default()
        },
        cancel,
        &Environment::default(),
        ParentLoss::Terminate,
        None,
    )?;
    if output.exit_code == Some(2) {
        Err(Error::Unavailable)
    } else if output.success() {
        Ok(output)
    } else {
        Err(Error::Launch("private host discovery failed".into()))
    }
}
/// Nur der private GTK-freie libexec-Helfer ruft diesen Eintritt auf.
pub fn resolve_worker(name: &std::ffi::OsStr) -> i32 {
    match resolve_local(name) {
        Some(path) => {
            if io::stdout().write_all(path.as_os_str().as_bytes()).is_ok() {
                0
            } else {
                1
            }
        }
        None => 2,
    }
}
/// Erkennt ausschließlich den bereits geerbten privaten Laufzeitkanal.
pub fn is_active() -> Result<bool, Error> {
    client().map(|stream| stream.is_some())
}
/// Interne Discovery benutzt denselben Hostsnapshot wie die Ausführung.
pub fn resolve_program(name: &std::ffi::OsStr) -> Result<Option<std::path::PathBuf>, Error> {
    let Some(channel) = client()? else {
        return Ok(resolve_local(name));
    };
    if name.is_empty() || name.as_bytes().contains(&0) || name.as_bytes().len() > 65536 {
        return Err(Error::InvalidPolicy);
    }
    let (mut stream, server) = UnixStream::pair().map_err(io_error)?;
    send_fd(channel, server.as_raw_fd()).map_err(io_error)?;
    drop(server);
    let mut e = Encoder(Vec::new());
    e.write_os(name);
    let deadline = Instant::now() + Duration::from_secs(5);
    frame(&mut stream, 4, &e.0, deadline, None).map_err(io_error)?;
    let (tag, b) = receive(&mut stream, 65536 + 1024, deadline, None).map_err(io_error)?;
    if tag != 3 {
        return Err(io_error(io::Error::other(
            "invalid host discovery response",
        )));
    }
    match decode_output(&b).map_err(io_error)? {
        Ok(out) => Ok(Some(OsString::from_vec(out.stdout).into())),
        Err(Error::Unavailable) => Ok(None),
        Err(e) => Err(e),
    }
}

/// Interner libexec-Einstieg vor dem ABI-Namespace und vor privaten LD-Exporten.
// Der private Owner startet auf seinem Hauptthread, bevor eigene Threads entstehen.
// Blockierte Stoppsignale werden synchron verarbeitet; das UI erbt die alte Maske.
struct LaunchSignals {
    watched: libc::sigset_t,
    previous: libc::sigset_t,
}
impl LaunchSignals {
    fn block() -> io::Result<Self> {
        unsafe {
            let mut watched = std::mem::zeroed();
            let mut previous = std::mem::zeroed();
            libc::sigemptyset(&mut watched);
            libc::sigaddset(&mut watched, libc::SIGTERM);
            libc::sigaddset(&mut watched, libc::SIGINT);
            libc::sigaddset(&mut watched, libc::SIGHUP);
            let code = libc::pthread_sigmask(libc::SIG_BLOCK, &watched, &mut previous);
            if code != 0 {
                return Err(io::Error::from_raw_os_error(code));
            }
            Ok(Self { watched, previous })
        }
    }
    fn poll(&self) -> io::Result<Option<i32>> {
        let timeout = libc::timespec {
            tv_sec: 0,
            tv_nsec: 20_000_000,
        };
        let signal = unsafe { libc::sigtimedwait(&self.watched, std::ptr::null_mut(), &timeout) };
        if signal >= 0 {
            return Ok(Some(signal));
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EAGAIN | libc::EINTR) => Ok(None),
            _ => Err(error),
        }
    }
}
impl Drop for LaunchSignals {
    fn drop(&mut self) {
        unsafe {
            let timeout = libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            };
            while libc::sigtimedwait(&self.watched, std::ptr::null_mut(), &timeout) >= 0 {}
            libc::pthread_sigmask(libc::SIG_SETMASK, &self.previous, std::ptr::null_mut());
        }
    }
}
pub fn launch(arguments: &[OsString]) -> io::Result<i32> {
    if std::env::var_os(FD_ENV).is_some() {
        return Err(io::Error::other(
            "private host owner must start before runtime entry",
        ));
    }
    if arguments.is_empty() {
        return Err(io::Error::other("missing private runtime command"));
    }
    let signals = LaunchSignals::block()?;
    let previous_mask = signals.previous;
    let (server, child_end) = UnixStream::pair()?;
    let fd = child_end.as_raw_fd();
    let mut command = Command::new(&arguments[0]);
    command
        .args(&arguments[1..])
        .env(FD_ENV, "3")
        .process_group(0);
    unsafe {
        command.pre_exec(move || {
            let code =
                libc::pthread_sigmask(libc::SIG_SETMASK, &previous_mask, std::ptr::null_mut());
            if code != 0 {
                return Err(io::Error::from_raw_os_error(code));
            }
            if libc::dup2(fd, 3) < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let shutdown = server.try_clone()?;
    let active = Arc::new(Mutex::new(Vec::<std::sync::Weak<AtomicBool>>::new()));
    let lost = Arc::new(AtomicBool::new(false));
    let tasks = active.clone();
    let owner_lost = lost.clone();
    let mut child = command.spawn()?;
    drop(child_end);
    let owner = thread::Builder::new()
        .name("fastra-host-owner".into())
        .spawn(move || {
            let mut workers = Vec::new();
            while !owner_lost.load(Ordering::Acquire) {
                let fd = match recv_fd(&server) {
                    Ok(Some(fd)) => fd,
                    _ => break,
                };
                // Bereits zugestellte Resultate dürfen ihr kurzes FD-Cleanup beenden.
                let admission_deadline = Instant::now() + Duration::from_millis(100);
                loop {
                    workers.retain(|w: &thread::JoinHandle<()>| !w.is_finished());
                    if workers.len() < MAX_ACTIVE
                        || Instant::now() >= admission_deadline
                        || owner_lost.load(Ordering::Acquire)
                    {
                        break;
                    }
                    thread::sleep(Duration::from_millis(1));
                }
                let cancel = Cancellation::default();
                let mut list = tasks.lock().unwrap();
                if owner_lost.load(Ordering::Acquire) {
                    break;
                }
                if workers.len() >= MAX_ACTIVE {
                    drop(list);
                    let mut stream = UnixStream::from(fd);
                    let _ = frame(
                        &mut stream,
                        3,
                        &encode_output(Err(Error::InvalidPolicy)),
                        Instant::now() + Duration::from_millis(100),
                        None,
                    );
                    continue;
                }
                list.retain(|c| c.strong_count() > 0);
                list.push(Arc::downgrade(&cancel.0));
                drop(list);
                if let Ok(worker) = thread::Builder::new()
                    .name("fastra-host-request".into())
                    .spawn(move || serve_request(UnixStream::from(fd), cancel, previous_mask))
                {
                    workers.push(worker)
                }
            }
            // Auch ein defekter Reader schließt den Kanal: kein scheinbar lebender, ungelesener Endpunkt.
            owner_lost.store(true, Ordering::Release);
            let _ = server.shutdown(Shutdown::Both);
            for c in tasks.lock().unwrap().iter() {
                if let Some(c) = c.upgrade() {
                    Cancellation(c).cancel()
                }
            }
            for worker in workers {
                let _ = worker.join();
            }
        });
    let owner = match owner {
        Ok(owner) => owner,
        Err(error) => {
            let _ = shutdown.shutdown(Shutdown::Both);
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    };
    let mut stop_signal = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(error) => break Err(error),
        }
        match signals.poll() {
            Ok(Some(signal)) => {
                stop_signal = Some(signal);
                lost.store(true, Ordering::Release);
                let _ = shutdown.shutdown(Shutdown::Both);
                for c in active.lock().unwrap().iter() {
                    if let Some(c) = c.upgrade() {
                        Cancellation(c).cancel()
                    }
                }
                // Das Kind bleibt bis nach KILL ungeerntet: seine Gruppen-ID kann nicht neu vergeben werden.
                unsafe {
                    libc::kill(-(child.id() as i32), signal);
                }
                thread::sleep(Duration::from_millis(250));
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                break child.wait();
            }
            Ok(None) => {}
            Err(error) => break Err(error),
        }
    };
    // Vor dem Drain keine neue Anfrage mehr akzeptieren, auch nicht aus bereits gepufferten FDs.
    lost.store(true, Ordering::Release);
    let _ = shutdown.shutdown(Shutdown::Both);
    for c in active.lock().unwrap().iter() {
        if let Some(c) = c.upgrade() {
            Cancellation(c).cancel()
        }
    }
    let _ = owner.join();
    if status.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let status = status?;
    Ok(stop_signal.map_or_else(
        || status.code().unwrap_or(128 + status.signal().unwrap_or(0)),
        |signal| 128 + signal,
    ))
}
