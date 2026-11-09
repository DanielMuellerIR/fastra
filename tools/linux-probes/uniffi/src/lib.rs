#[derive(Debug, uniffi::Error)]
pub enum ProbeError {
    Cancelled,
    InvalidInput,
}
impl std::fmt::Display for ProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ProbeError {}
#[uniffi::export]
pub fn copy_bytes(input: Vec<u8>, mode: u8) -> Result<Vec<u8>, ProbeError> {
    if mode == 1 { return Err(ProbeError::Cancelled); }
    if mode == 2 { panic!("decision probe panic"); }
    if input.len() > 1024 * 1024 || std::str::from_utf8(&input).is_err() {
        return Err(ProbeError::InvalidInput);
    }
    Ok(input)
}
uniffi::setup_scaffolding!();

#[derive(uniffi::Object)]
pub struct ProbeCancellation {
    cancelled: std::sync::atomic::AtomicBool,
    started: std::sync::atomic::AtomicBool,
}
#[uniffi::export]
impl ProbeCancellation {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { cancelled: false.into(), started: false.into() })
    }
    pub fn cancel(&self) { self.cancelled.store(true,std::sync::atomic::Ordering::Release); }
    pub fn was_started(&self) -> bool { self.started.load(std::sync::atomic::Ordering::Acquire) }
}
#[uniffi::export]
pub fn slow_copy(input: Vec<u8>, cancellation: std::sync::Arc<ProbeCancellation>) -> Result<Vec<u8>,ProbeError> {
    cancellation.started.store(true,std::sync::atomic::Ordering::Release);
    for _ in 0..5000 {
        if cancellation.cancelled.load(std::sync::atomic::Ordering::Acquire) { return Err(ProbeError::Cancelled); }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    Ok(input)
}
