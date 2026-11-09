//! Dateisnapshots und explizite Vorschautransaktionen; keine neue Suche beim Apply.
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;

#[cfg(target_os = "linux")]
pub mod code_explanation;

#[cfg(target_os = "linux")]
pub mod local_control;

#[cfg(target_os = "linux")]
mod runtime_paths;
#[cfg(target_os = "linux")]
pub use runtime_paths::{check_runtime_file, check_runtime_path, initialize_runtime_policy};
