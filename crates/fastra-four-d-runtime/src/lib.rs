//! Interne Tool4D-Protokolle und besessene Sandboxprozesse ohne GTK-Abhängigkeit.
pub mod macro_run;
pub mod read;
mod secure_path;
pub use secure_path::open_path;
use std::path::{Path, PathBuf};
fn worker_layout() -> Result<(PathBuf, PathBuf), String> {
    let application = std::env::current_exe()
        .and_then(|path| path.canonicalize())
        .map_err(|e| e.to_string())?;
    let app = if fastra_process::host::is_active().map_err(|e| e.to_string())? {
        let helper = application.with_file_name("fastra-4d-worker");
        fastra_process::host::resolve_program(helper.as_os_str())
            .map_err(|e| e.to_string())?
            .ok_or("Packaged GTK-free 4D worker missing")?
    } else {
        application
    };
    let lib = app
        .parent()
        .and_then(Path::parent)
        .ok_or("Application layout")?
        .join("lib");
    Ok((app, lib))
}
