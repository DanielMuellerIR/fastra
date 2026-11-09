//! Privater libexec-Einstieg; der Sandboxvertrag benötigt ausschließlich Standardpipes.
fn main() {
    if fastra_process::host::is_active().unwrap_or(true) {
        std::process::exit(2);
    }
    // Auch ein versehentlich ohne Marker geerbter Hostkanal darf die Sandbox nicht erreichen.
    if unsafe { libc::close_range(3, u32::MAX, 0) } != 0 {
        std::process::exit(1);
    }
    let result = fastra_four_d_runtime::read::worker_entry()
        .or_else(fastra_four_d_runtime::macro_run::worker_entry);
    std::process::exit(result.unwrap_or(2));
}
