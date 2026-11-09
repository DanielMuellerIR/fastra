use super::*;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    time::{Duration, Instant},
};
const HEADER: usize = 8192;
const MESSAGE: usize = 1024 * 1024;
const TOTAL: usize = 4 * 1024 * 1024;
pub(super) fn entry() -> i32 {
    let result = std::panic::catch_unwind(|| -> Result<Response> {
        let mut input = Vec::new();
        std::io::stdin()
            .take((MAX_JSON + 1) as u64)
            .read_to_end(&mut input)
            .map_err(io_error)?;
        if input.len() > MAX_JSON {
            return Err(error(ErrorKind::Limit, "Input JSON"));
        }
        let request: Request = serde_json::from_slice(&input)
            .map_err(|_| error(ErrorKind::Protocol, "Invalid worker request"))?;
        run(request)
    })
    .unwrap_or_else(|_| Err(error(ErrorKind::Panic, "Worker failed")));
    let envelope = Envelope { version: 1, result };
    let bytes = serde_json::to_vec(&envelope)
        .ok()
        .filter(|bytes| bytes.len() <= MAX_OUTPUT)
        .unwrap_or_else(|| {
            serde_json::to_vec(&Envelope {
                version: 1,
                result: Err(error(ErrorKind::Limit, "Worker result: 1 MiB")),
            })
            .unwrap_or_default()
        });
    i32::from(std::io::stdout().write_all(&bytes).is_err())
}

struct Process {
    cancel: process::Cancellation,
    rx: mpsc::Receiver<std::result::Result<process::Output, process::Error>>,
    result: Option<std::result::Result<process::Output, process::Error>>,
}
impl Process {
    fn finished(&mut self) -> bool {
        if self.result.is_none() {
            if let Ok(result) = self.rx.try_recv() {
                self.result = Some(result);
            }
        }
        self.result.is_some()
    }
    fn finish(&mut self) {
        if self.result.is_none() {
            if let Ok(result) = self.rx.recv_timeout(Duration::from_secs(2)) {
                self.result = Some(result);
            }
        }
        if self.result.is_none() {
            self.cancel.cancel();
            if let Ok(result) = self.rx.recv_timeout(Duration::from_millis(700)) {
                self.result = Some(result);
            }
        }
    }
    fn failure(&self) -> Error {
        match self.result.as_ref() {
            Some(Ok(out)) => error(
                ErrorKind::Process,
                format!(
                    "tool4d exit {:?}, signal {:?}: {}",
                    out.exit_code,
                    out.signal,
                    text(&out.stderr)
                ),
            ),
            Some(Err(process::Error::Cancelled(output))) => error(
                ErrorKind::Process,
                format!(
                    "tool4d required cleanup after shutdown: {}",
                    text(&output.stderr)
                ),
            ),
            Some(Err(e)) => process_error(e.clone()),
            None => error(
                ErrorKind::Process,
                "tool4d did not stop within its grace period",
            ),
        }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
fn launch(port: u16) -> Process {
    let cancel = process::Cancellation::default();
    let child_cancel = cancel.clone();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = process::run_in(
            process::Domain::Isolated,
            Path::new("/runtime/tool4d"),
            Path::new("/tmp"),
            &[format!("--lsp={port}").into()],
            Policy {
                timeout: Duration::from_secs(18),
                termination_grace: Duration::from_millis(100),
                stdout_bytes: 16 * 1024,
                stderr_bytes: 16 * 1024,
            },
            &child_cancel,
            &Environment {
                remove_prefixes: vec!["LD_".into(), "GCONV_PATH".into()],
                set: vec![("LD_LIBRARY_PATH".into(), "/runtime/lib".into())],
            },
        );
        let _ = tx.send(result);
    });
    Process {
        cancel,
        rx,
        result: None,
    }
}
fn run(request: Request) -> Result<Response> {
    if request.source.len() > MAX_SOURCE || request.token.len() > 64 || request.token.is_empty() {
        return Err(error(ErrorKind::Limit, "Request/source limit"));
    }
    validate_relative(&request.relative)?;
    let _runtime_bindings = verify_runtime_mounts(Path::new("/runtime"), &request.runtime)?;
    let own = fs::read_link("/proc/self/ns/net").map_err(io_error)?;
    if own.to_string_lossy() == request.parent_net || request.parent_net.len() > 128 {
        return Err(error(
            ErrorKind::Isolation,
            "Worker network namespace is not isolated",
        ));
    }
    let interfaces = fs::read_to_string("/proc/net/dev").map_err(io_error)?;
    if interfaces
        .lines()
        .skip(2)
        .filter_map(|l| l.split_once(':'))
        .any(|(name, _)| name.trim() != "lo")
    {
        return Err(error(
            ErrorKind::Isolation,
            "Only private loopback is allowed",
        ));
    }
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let root_meta = fs::symlink_metadata("/workspace").map_err(io_error)?;
    if !root_meta.is_dir() || (root_meta.dev(), root_meta.ino()) != request.root_identity {
        return Err(error(ErrorKind::Stale, "Mounted project identity changed"));
    }
    if request.source_bytes > 32 * 1024 * 1024 {
        return Err(error(ErrorKind::Limit, "Saved source bytes"));
    }
    let source_path = Path::new("/workspace").join(&request.relative);
    let source_file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&source_path)
        .map_err(io_error)?;
    let source_meta = source_file.metadata().map_err(io_error)?;
    if !source_meta.is_file()
        || (source_meta.dev(), source_meta.ino()) != request.source_identity
        || source_meta.len() != request.source_bytes as u64
    {
        return Err(error(ErrorKind::Stale, "Mounted source identity changed"));
    }
    let mut original = Vec::new();
    source_file
        .take((request.source_bytes + 1) as u64)
        .read_to_end(&mut original)
        .map_err(io_error)?;
    use sha2::{Digest, Sha256};
    if original.len() != request.source_bytes
        || <[u8; 32]>::from(Sha256::digest(&original)) != request.source_hash
    {
        return Err(error(ErrorKind::Stale, "Mounted source bytes changed"));
    }
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).map_err(io_error)?;
    listener.set_nonblocking(true).map_err(io_error)?;
    let mut child = launch(listener.local_addr().map_err(io_error)?.port());
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut retained_connection = None;
    let result = (|| -> Result<Response> {
        let stream = loop {
            if Instant::now() >= deadline {
                return Err(error(ErrorKind::Limit, "LSP connection deadline"));
            }
            if child.finished() {
                return Err(child.failure());
            }
            match listener.accept() {
                Ok((stream, address)) => {
                    if !address.ip().is_loopback() {
                        return Err(error(ErrorKind::Isolation, "Foreign LSP connection"));
                    }
                    break stream;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(e) => return Err(io_error(e)),
            }
        };
        stream.set_nodelay(true).map_err(io_error)?;
        stream
            .set_read_timeout(Some(Duration::from_millis(100)))
            .map_err(io_error)?;
        stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .map_err(io_error)?;
        let mut rpc = Rpc {
            stream,
            buffer: Vec::new(),
            total: 0,
            messages: 0,
            deadline,
        };
        let uri = format!("file:///workspace/{}", encode_uri(&request.relative));
        rpc.send(json!({"id":1,"method":"initialize","params":{"processId":std::process::id(),"rootUri":"file:///workspace","workspaceFolders":[{"uri":"file:///workspace","name":"Fastra read-only project"}],"capabilities":{"textDocument":{"diagnostic":{"dynamicRegistration":false},"publishDiagnostics":{"relatedInformation":true}}},"initializationOptions":{"diagnostics":{"enable":true,"scope":"Document"},"dependencies":{"enable":false}}}}))?;
        let init = rpc.response(1)?;
        let caps = init
            .get("capabilities")
            .ok_or_else(|| error(ErrorKind::Protocol, "Missing server capabilities"))?;
        if !caps.get("diagnosticProvider").is_some_and(Value::is_object) {
            return Err(error(
                ErrorKind::Protocol,
                "Pull diagnostics provider required",
            ));
        }
        let server = init
            .get("serverInfo")
            .and_then(|s| s.get("version"))
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        if server.len() > 128 {
            return Err(error(ErrorKind::Limit, "Server version"));
        }
        let server = server.to_owned();
        rpc.send(json!({"method":"initialized","params":{}}))?;
        rpc.send(json!({"method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"4d","version":1,"text":request.source}}}))?;
        rpc.send(json!({"method":"textDocument/didChange","params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[{"text":request.source}]}}))?;
        let mut response = Response {
            token: request.token,
            server,
            cleanup_forced: false,
            diagnostics: Vec::new(),
            signatures: Vec::new(),
        };
        match request.operation {
            Operation::Diagnostics => {
                rpc.send(json!({"id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":uri},"previousResultId":null}}))?;
                let result = rpc.response(2)?;
                let items = result
                    .get("items")
                    .and_then(Value::as_array)
                    .ok_or_else(|| error(ErrorKind::NoDiagnostics, "No full diagnostic result"))?;
                if result.get("kind").and_then(Value::as_str) != Some("full") {
                    return Err(error(
                        ErrorKind::NoDiagnostics,
                        "Full diagnostic result required",
                    ));
                }
                if items.len() > 200 {
                    return Err(error(
                        ErrorKind::Limit,
                        "At most 200 diagnostics; no partial result",
                    ));
                }
                for item in items {
                    let range: Range =
                        serde_json::from_value(item.get("range").cloned().ok_or_else(|| {
                            error(ErrorKind::Protocol, "Diagnostic range missing")
                        })?)
                        .map_err(|_| error(ErrorKind::Protocol, "Invalid diagnostic range"))?;
                    let message = item
                        .get("message")
                        .and_then(Value::as_str)
                        .ok_or_else(|| error(ErrorKind::Protocol, "Diagnostic message missing"))?;
                    if message.len() > 8192 {
                        return Err(error(ErrorKind::Limit, "Diagnostic message"));
                    }
                    let severity = item.get("severity").and_then(Value::as_u64).unwrap_or(1);
                    if !(1..=4).contains(&severity) {
                        return Err(error(ErrorKind::Protocol, "Invalid diagnostic severity"));
                    }
                    response.diagnostics.push(Diagnostic {
                        range,
                        severity: severity as u8,
                        message: message.into(),
                    });
                }
            }
            Operation::Signature => {
                if caps.get("signatureHelpProvider").is_none() {
                    return Err(error(ErrorKind::Protocol, "Signature provider unavailable"));
                }
                let cursor = request
                    .cursor
                    .ok_or_else(|| error(ErrorKind::Source, "Cursor required"))?;
                rpc.send(json!({"id":2,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":uri},"position":cursor,"context":{"triggerKind":1}}}))?;
                let result = rpc.response(2)?;
                if !result.is_null() {
                    let signatures = result
                        .get("signatures")
                        .and_then(Value::as_array)
                        .ok_or_else(|| error(ErrorKind::Protocol, "Invalid signature result"))?;
                    if signatures.len() > 8 {
                        return Err(error(ErrorKind::Limit, "At most 8 signatures"));
                    }
                    for signature in signatures {
                        let label = signature
                            .get("label")
                            .and_then(Value::as_str)
                            .ok_or_else(|| error(ErrorKind::Protocol, "Signature label missing"))?;
                        let documentation = signature
                            .get("documentation")
                            .and_then(|v| {
                                v.as_str()
                                    .or_else(|| v.get("value").and_then(Value::as_str))
                            })
                            .unwrap_or("");
                        if label.len() > 16384 || documentation.len() > 16384 {
                            return Err(error(ErrorKind::Limit, "Signature text"));
                        }
                        let active_parameter = signature
                            .get("activeParameter")
                            .or_else(|| result.get("activeParameter"))
                            .and_then(Value::as_u64)
                            .map(|n| n as usize);
                        if active_parameter.is_some_and(|n| n > 1024) {
                            return Err(error(ErrorKind::Protocol, "Invalid active parameter"));
                        }
                        response.signatures.push(Signature {
                            label: label.into(),
                            documentation: documentation.into(),
                            active_parameter,
                        });
                    }
                }
            }
        }
        // Wie beim Mac-Adapter darf ein Shutdown-Hänger kein bereits vollständiges Leseergebnis vernichten.
        rpc.deadline = Instant::now() + Duration::from_millis(500);
        let orderly = (|| -> Result<()> {
            rpc.send(
                json!({"method":"textDocument/didClose","params":{"textDocument":{"uri":uri}}}),
            )?;
            rpc.send(json!({"id":3,"method":"shutdown","params":null}))?;
            rpc.response(3)?;
            Ok(())
        })();
        response.cleanup_forced = orderly.is_err();
        if rpc.send(json!({"method":"exit","params":null})).is_err() {
            response.cleanup_forced = true;
        }
        retained_connection = Some(rpc);
        Ok(response)
    })();
    if result.is_err() {
        child.finished();
        if child.result.is_none() {
            if let Ok(output) = child.rx.recv_timeout(Duration::from_millis(50)) {
                child.result = Some(output);
            }
        }
        child.cancel.cancel();
    }
    child.finish();
    drop(retained_connection);
    let mut result = result;
    if let Ok(response) = &mut result {
        let (output, forced) = match &child.result {
            Some(Ok(output)) if output.success() => (output, false),
            Some(Err(process::Error::Cancelled(output))) => (output, true),
            _ => return Err(child.failure()),
        };
        if !output.stdout.is_empty() {
            return Err(error(
                ErrorKind::Process,
                format!(
                    "Unexpected tool4d stdout in read-only mode: {}",
                    text(&output.stdout)
                ),
            ));
        }
        response.cleanup_forced |= forced;
    }
    result.map_err(|mut e| {
        let output = match child.result.as_ref() {
            Some(Ok(output)) => Some(output),
            Some(Err(
                process::Error::Cancelled(output)
                | process::Error::TimedOut(output)
                | process::Error::OutputLimit(output),
            )) => Some(output),
            Some(Err(process::Error::Capture { output, .. })) => Some(output),
            _ => None,
        };
        if let Some(output) = output {
            e.detail = format!(
                "{} · tool4d exit {:?}, signal {:?}: {}",
                e.detail,
                output.exit_code,
                output.signal,
                text(&output.stderr)
            );
        }
        e
    })
}
fn encode_uri(path: &str) -> String {
    let mut out = String::new();
    for b in path.as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(b) {
            out.push(*b as char);
        } else {
            use std::fmt::Write;
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}
struct Rpc {
    stream: TcpStream,
    buffer: Vec<u8>,
    total: usize,
    messages: usize,
    deadline: Instant,
}
impl Rpc {
    fn send(&mut self, mut value: Value) -> Result<()> {
        value
            .as_object_mut()
            .ok_or_else(|| error(ErrorKind::Protocol, "JSON object required"))?
            .insert("jsonrpc".into(), Value::String("2.0".into()));
        let bytes = serde_json::to_vec(&value).map_err(io_error)?;
        if bytes.len() > MAX_JSON {
            return Err(error(ErrorKind::Limit, "LSP outgoing JSON"));
        }
        let mut frame = format!("Content-Length: {}\r\n\r\n", bytes.len()).into_bytes();
        frame.extend_from_slice(&bytes);
        self.stream.write_all(&frame).map_err(io_error)
    }
    fn receive(&mut self) -> Result<Value> {
        loop {
            if Instant::now() >= self.deadline {
                return Err(error(ErrorKind::Limit, "LSP deadline: 15 s"));
            }
            if let Some(end) = self.buffer.windows(4).position(|s| s == b"\r\n\r\n") {
                if end > HEADER {
                    return Err(error(ErrorKind::Limit, "LSP header"));
                }
                let header = std::str::from_utf8(&self.buffer[..end])
                    .map_err(|_| error(ErrorKind::Protocol, "Invalid LSP header"))?;
                let lengths: Vec<_> = header
                    .split("\r\n")
                    .filter_map(|s| s.split_once(':'))
                    .filter(|(key, _)| key.eq_ignore_ascii_case("Content-Length"))
                    .map(|(_, value)| value.trim().parse::<usize>())
                    .collect();
                if lengths.len() != 1 {
                    return Err(error(ErrorKind::Protocol, "One Content-Length required"));
                }
                let length = lengths[0]
                    .as_ref()
                    .map_err(|_| error(ErrorKind::Protocol, "Invalid Content-Length"))?;
                if *length > MESSAGE {
                    return Err(error(ErrorKind::Limit, "LSP message: 1 MiB"));
                }
                if self.buffer.len() >= end + 4 + *length {
                    self.messages += 1;
                    if self.messages > 128 {
                        return Err(error(ErrorKind::Limit, "LSP message count"));
                    }
                    let value = serde_json::from_slice(&self.buffer[end + 4..end + 4 + *length])
                        .map_err(|_| error(ErrorKind::Protocol, "Invalid LSP JSON"))?;
                    self.buffer.drain(..end + 4 + *length);
                    return Ok(value);
                }
            } else if self.buffer.len() > HEADER {
                return Err(error(ErrorKind::Limit, "LSP header"));
            }
            let mut block = [0u8; 8192];
            match self.stream.read(&mut block) {
                Ok(0) => return Err(error(ErrorKind::Protocol, "LSP connection closed")),
                Ok(n) => {
                    self.total += n;
                    if self.total > TOTAL {
                        return Err(error(ErrorKind::Limit, "LSP total bytes"));
                    }
                    self.buffer.extend_from_slice(&block[..n]);
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(e) => return Err(io_error(e)),
            }
        }
    }
    fn response(&mut self, id: u64) -> Result<Value> {
        loop {
            let message = self.receive().map_err(|mut e| {
                e.detail = format!("LSP response {id}: {}", e.detail);
                e
            })?;
            if message.get("id").and_then(Value::as_u64) == Some(id)
                && (message.get("result").is_some() || message.get("error").is_some())
            {
                if message.get("error").is_some() {
                    return Err(error(ErrorKind::Protocol, "LSP request refused"));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
            if let (Some(request_id), Some(method)) = (
                message.get("id"),
                message.get("method").and_then(Value::as_str),
            ) {
                match method{"workspace/configuration"=>{let items=message.get("params").and_then(|p|p.get("items")).and_then(Value::as_array).map_or(0,Vec::len);if items>32{return Err(error(ErrorKind::Limit,"Configuration items"));}self.send(json!({"id":request_id,"result":vec![json!({"diagnostics":{"enable":true,"scope":"Document"},"dependencies":{"enable":false}});items]}))?;},"workspace/workspaceFolders"=>self.send(json!({"id":request_id,"result":[{"uri":"file:///workspace","name":"Fastra read-only project"}]}))?,"window/workDoneProgress/create"|"client/registerCapability"=>self.send(json!({"id":request_id,"result":null}))?,"workspace/applyEdit"=>self.send(json!({"id":request_id,"result":{"applied":false,"failureReason":"Read-only Fastra adapter"}}))?,_=>self.send(json!({"id":request_id,"error":{"code":-32601,"message":"Unsupported read-only client request"}}))?,}
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn pair() -> (Rpc, Rpc) {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        for stream in [&client, &server] {
            stream
                .set_read_timeout(Some(Duration::from_millis(20)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_millis(100)))
                .unwrap();
        }
        let make = |stream| Rpc {
            stream,
            buffer: Vec::new(),
            total: 0,
            messages: 0,
            deadline: Instant::now() + Duration::from_secs(1),
        };
        (make(client), make(server))
    }
    #[test]
    fn fragmented_framing_and_combined_messages() {
        let (mut client, mut server) = pair();
        let producer = std::thread::spawn(move || {
            let a = b"Content-Length: 8\r\n\r\n{\"id\":1}";
            for part in a.chunks(3) {
                server.stream.write_all(part).unwrap();
            }
            server.send(json!({"id":2,"result":null})).unwrap();
        });
        assert_eq!(client.receive().unwrap()["id"], 1);
        assert_eq!(client.receive().unwrap()["id"], 2);
        producer.join().unwrap();
    }
    #[test]
    fn malformed_and_oversized_messages_fail_closed() {
        for bytes in [
            b"X-Test: 2\r\n\r\n{}".as_slice(),
            b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            b"Content-Length: 9999999\r\n\r\n",
            b"Content-Length: -1\r\n\r\n",
            b"Content-Length: 1\r\n\r\n!",
        ] {
            let (mut client, mut server) = pair();
            server.stream.write_all(bytes).unwrap();
            assert!(client.receive().is_err());
        }
    }
    #[test]
    fn excessive_headers_message_counts_and_timeouts_are_bounded() {
        let (mut client, mut server) = pair();
        server.stream.write_all(&vec![b'x'; HEADER + 1]).unwrap();
        assert!(client.receive().is_err());
        let (mut client, mut server) = pair();
        for _ in 0..129 {
            server.send(json!({"method":"test"})).unwrap();
        }
        for _ in 0..128 {
            client.receive().unwrap();
        }
        assert!(matches!(
            client.receive().unwrap_err().kind,
            ErrorKind::Limit
        ));
        let (mut client, _server) = pair();
        client.deadline = Instant::now() + Duration::from_millis(30);
        assert!(matches!(
            client.receive().unwrap_err().kind,
            ErrorKind::Limit
        ));
    }
    #[test]
    fn source_edits_are_refused_while_readonly_result_arrives() {
        let (mut client, mut server) = pair();
        let producer = std::thread::spawn(move || {
            server.send(json!({"id":"server-edit","method":"workspace/applyEdit","params":{"edit":{"changes":{"file:///workspace/Project/Sources/Methods/x.4dm":[{"newText":"unwanted"}]}}}})).unwrap();
            server.send(json!({"id":1,"result":{"ok":true}})).unwrap();
            let refused = server.receive().unwrap();
            assert_eq!(refused["result"]["applied"], false);
        });
        assert_eq!(client.response(1).unwrap()["ok"], true);
        producer.join().unwrap();
    }
    #[test]
    fn uri_encoding_keeps_literal_path_identity() {
        assert_eq!(
            encode_uri("Project/Sources/Methods/a #é\\🙂.4dm"),
            "Project/Sources/Methods/a%20%23%C3%A9%5C%F0%9F%99%82.4dm"
        );
    }
}
