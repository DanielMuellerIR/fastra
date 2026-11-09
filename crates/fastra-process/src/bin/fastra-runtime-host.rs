fn main() {
    #[cfg(target_os = "linux")]
    {
        let mut args = std::env::args_os().skip(1);
        let entry = args.next();
        if entry.as_deref() == Some(std::ffi::OsStr::new("--internal-resolve")) {
            let Some(name) = args.next() else {
                std::process::exit(2)
            };
            if args.next().is_some() {
                std::process::exit(2)
            }
            std::process::exit(fastra_process::host::resolve_worker(&name));
        }
        if entry.as_deref() != Some(std::ffi::OsStr::new("--")) {
            eprintln!("private runtime launcher requires -- COMMAND [ARG...]");
            std::process::exit(2)
        }
        match fastra_process::host::launch(&args.collect::<Vec<_>>()) {
            Ok(code) => std::process::exit(code),
            Err(_) => {
                eprintln!("private runtime launcher failed");
                std::process::exit(1)
            }
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::process::exit(2);
    }
}
