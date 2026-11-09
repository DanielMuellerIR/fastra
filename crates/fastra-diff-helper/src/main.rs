use fastra_diff_helper::*;
use gio::{
    glib::{self, prelude::*},
    prelude::*,
};
use std::{
    io::Write,
    process::{Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};
fn application() -> Result<std::path::PathBuf, i32> {
    #[cfg(target_os = "linux")]
    if fastra_io::local_control::transport::service_target().map_err(|_| 5)?
        == fastra_io::local_control::transport::ServiceTarget::Native
    {
        return fastra_io::local_control::transport::native_launcher("fastra-diff").map_err(|_| 5);
    }
    Ok(std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|_| 5)?
        .parent()
        .ok_or(5)?
        .join("fastra-linux"))
}

fn execute() -> Result<(), i32> {
    #[cfg(target_os = "linux")]
    fastra_io::local_control::transport::service_target().map_err(|_| 5)?;
    let started_wall = now();
    let deadline = Instant::now() + Duration::from_secs(10);
    let args = std::env::args_os()
        .skip(1)
        .map(|v| v.into_string().map_err(|_| 2))
        .collect::<Result<Vec<_>, _>>()?;
    if args == ["--capabilities", "--json"] {
        std::io::stdout()
            .lock()
            .write_all(format!("{CAPABILITIES}\n").as_bytes())
            .map_err(|_| 6)?;
        return Ok(());
    }
    let Some(mut request) = Request::parse(&args, &std::env::current_dir().map_err(|_| 2)?)? else {
        std::io::stdout()
            .lock()
            .write_all(format!("{CAPABILITIES}\n").as_bytes())
            .map_err(|_| 6)?;
        return Ok(());
    };
    request.deadline = started_wall + 10.;
    let (tx, rx) = mpsc::sync_channel(1);
    let files = request.clone();
    std::thread::spawn(move || {
        let _ = tx.send(files.validate_files());
    });
    rx.recv_timeout(deadline.saturating_duration_since(Instant::now()))
        .map_err(|_| 6)??;
    let bus = bus()?;
    let application = application()?;
    if !application.is_file() {
        return Err(5);
    }
    let cancel = gio::Cancellable::new();
    let timer = cancel.clone();
    std::thread::spawn(move || {
        std::thread::sleep(deadline.saturating_duration_since(Instant::now()));
        timer.cancel();
    });
    let address =
        gio::dbus_address_get_for_bus_sync(gio::BusType::Session, Some(&cancel)).map_err(|_| 6)?;
    if !local_bus_address(&address) {
        return Err(6);
    }
    let connection = gio::bus_get_sync(gio::BusType::Session, Some(&cancel)).map_err(|_| 6)?;
    let payload = request.encode()?;
    let mut launched = false;
    while Instant::now() < deadline {
        let remaining = deadline
            .saturating_duration_since(Instant::now())
            .as_millis()
            .min(i32::MAX as u128) as i32;
        let owner = connection
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "NameHasOwner",
                Some(&(bus,).to_variant()),
                None,
                gio::DBusCallFlags::NONE,
                remaining,
                Some(&cancel),
            )
            .ok()
            .and_then(|v| v.get::<(bool,)>())
            .is_some_and(|v| v.0);
        if owner {
            if let Ok(reply) = connection.call_sync(
                Some(bus),
                PATH,
                INTERFACE,
                "Deliver",
                Some(&(payload.as_str(),).to_variant()),
                Some(glib::VariantTy::new("(i)").unwrap()),
                gio::DBusCallFlags::NONE,
                remaining,
                Some(&cancel),
            ) {
                let (code,) = reply.get::<(i32,)>().ok_or(6)?;
                return match code {
                    0 => Ok(()),
                    2..=4 => Err(code),
                    _ => Err(6),
                };
            }
        }
        if !launched && !owner && Instant::now() < deadline {
            let mut child = Command::new(&application)
                .arg("--external-diff-service")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| 5)?;
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            launched = true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Err(6)
}
fn main() {
    if let Err(code) = execute() {
        eprintln!("fastra-diff: {}", diagnostic(code));
        std::process::exit(code);
    }
}
