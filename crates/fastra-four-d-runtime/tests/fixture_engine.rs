//! Ausschließlich synthetisches Prüftool; kein Tool4D-Ersatz und kein Enginekompatibilitätsbeleg.
use serde_json::{json, Value};
use std::{
    io::{BufRead, Read, Write},
    net::{Ipv4Addr, TcpStream},
    path::Path,
};
fn environment() {
    assert!(std::env::var_os("FASTRA_INTERNAL_HOST_FD").is_none());
    assert_eq!(std::env::var("LD_LIBRARY_PATH").unwrap(), "/runtime/lib");
    assert!(!Path::new("/etc/hostname").exists());
    for entry in std::fs::read_dir("/proc/self/fd").unwrap().flatten() {
        let link = std::fs::read_link(entry.path()).unwrap();
        assert!(
            !link.as_os_str().as_encoded_bytes().starts_with(b"socket:"),
            "ambient socket inherited"
        );
    }
}
fn resist() -> ! {
    unsafe {
        libc::signal(libc::SIGTERM, libc::SIG_IGN);
        if libc::fork() == 0 {
            libc::setsid();
            loop {
                libc::pause();
            }
        }
        loop {
            libc::pause();
        }
    }
}
fn frame(reader: &mut std::io::BufReader<TcpStream>) -> Value {
    let mut length = None;
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0);
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            length = Some(value.trim().parse::<usize>().unwrap());
        }
    }
    let mut bytes = vec![0; length.unwrap()];
    reader.read_exact(&mut bytes).unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
fn send(stream: &mut TcpStream, id: Value, result: Value) {
    let bytes = serde_json::to_vec(&json!({"jsonrpc":"2.0", "id":id,"result":result})).unwrap();
    write!(stream, "Content-Length: {}\r\n\r\n", bytes.len()).unwrap();
    stream.write_all(&bytes).unwrap();
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if !args.first().is_some_and(|arg| arg.starts_with("--lsp="))
        && !args.iter().any(|arg| arg == "--user-param")
    {
        println!("Fixture driver only; native gate invokes the executable explicitly.");
        return;
    }
    environment();
    if let Some(port) = args.first().and_then(|a| a.strip_prefix("--lsp=")) {
        let mut stream =
            TcpStream::connect((Ipv4Addr::LOCALHOST, port.parse::<u16>().unwrap())).unwrap();
        let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
        loop {
            let message = frame(&mut reader);
            match message["method"].as_str().unwrap_or("") {
                "initialize" => send(
                    &mut stream,
                    message["id"].clone(),
                    json!({"capabilities":{"diagnosticProvider":{},"signatureHelpProvider":{}},"serverInfo":{"version":"fixture-not-real-tool4d"}}),
                ),
                "textDocument/didOpen"
                    if message["params"]["textDocument"]["text"]
                        .as_str()
                        .unwrap()
                        .contains("SLOW") =>
                {
                    resist()
                }
                "textDocument/diagnostic" => send(
                    &mut stream,
                    message["id"].clone(),
                    json!({"kind":"full", "items":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":2,"message":"synthetic diagnostic"}]}),
                ),
                "textDocument/signatureHelp" => send(
                    &mut stream,
                    message["id"].clone(),
                    json!({"signatures":[{"label":"Probe(Text)","documentation":"synthetic signature","parameters":[]}],"activeSignature":0,"activeParameter":0}),
                ),
                "shutdown" => send(&mut stream, message["id"].clone(), Value::Null),
                "exit" => break,
                _ => {}
            }
        }
    } else {
        let spec = &args[args.iter().position(|a| a == "--user-param").unwrap() + 1];
        let fields: Vec<_> = spec.split('|').collect();
        assert_eq!(fields.len(), 4);
        assert!(!Path::new("/engine/userPreferences.original/debuggerWatches.json").exists());
        let input = std::fs::read_to_string(fields[0]).unwrap();
        if input.contains("SLOW") {
            resist();
        }
        std::fs::write("/engine/private-runtime-write", "private copy only").unwrap();
        std::fs::write(fields[1], format!("// isolated result\n{input}")).unwrap();
        std::fs::write(format!("{}.status", fields[1]), "OK\n").unwrap();
        std::process::exit(7);
    }
}
