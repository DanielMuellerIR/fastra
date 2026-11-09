//! Privater libexec-Einstieg für den vom Host-Git gestarteten Commit-Hook.
fn main() {
    std::process::exit(fastra_git::commit_hook_entry().unwrap_or(2));
}
