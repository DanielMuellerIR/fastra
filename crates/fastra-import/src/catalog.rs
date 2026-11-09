//! Kurzlebiger Katalogcache, an die tatsächliche Werkzeugdatei gebunden.
use crate::{Cancellation, Catalog, Error, Importer, Limits, Policy};
use std::{
    fs,
    os::unix::fs::MetadataExt,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
#[derive(Clone)]
pub struct ToolCatalog {
    pub catalog: Catalog,
    pub supports_progress: bool,
}
#[derive(Clone, PartialEq, Eq)]
struct ToolIdentity {
    path: PathBuf,
    values: (u64, u64, u64, i64, i64, i64, i64),
}
impl ToolIdentity {
    fn read(importer: &Importer) -> Result<Self, Error> {
        let path = fs::canonicalize(&importer.executable).map_err(crate::io)?;
        if path.to_str().is_none() {
            return Err(Error::InvalidPath("non-UTF-8 tool identity"));
        }
        let m = fs::metadata(&path).map_err(crate::io)?;
        if !m.is_file() {
            return Err(Error::InvalidPath("tool must be a regular file"));
        }
        Ok(Self {
            path,
            values: (
                m.dev(),
                m.ino(),
                m.len(),
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec(),
            ),
        })
    }
}
struct Entry {
    identity: ToolIdentity,
    probed: Instant,
    value: ToolCatalog,
    json_bytes: usize,
}
static CACHE: OnceLock<Mutex<Vec<Entry>>> = OnceLock::new();
impl Importer {
    pub fn probe_cached(
        &self,
        mut policy: Policy,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<ToolCatalog, Error> {
        limits.check()?;
        crate::check_cancel(cancel)?;
        let identity = ToolIdentity::read(self)?;
        let cache = CACHE.get_or_init(Default::default);
        if let Some(value) = cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|e| {
                e.identity == identity
                    && e.probed.elapsed() < Duration::from_secs(300)
                    && e.json_bytes <= limits.max_json_bytes
            })
            .map(|e| e.value.clone())
        {
            return Ok(value);
        }
        policy.timeout = policy.timeout.min(Duration::from_secs(10));
        policy.stdout_bytes = policy.stdout_bytes.min(1024 * 1024);
        let (catalog, catalog_output) = self.catalog(policy, limits, cancel)?;
        let help = self.run(
            std::path::Path::new("/"),
            &["--help".into()],
            policy,
            limits,
            cancel,
            None,
        );
        crate::check_cancel(cancel)?;
        let supports_progress = help
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .is_some_and(|help| {
                help.lines()
                    .any(|line| line.split_whitespace().next() == Some("--progress"))
            });
        if ToolIdentity::read(self)? != identity {
            return Err(Error::Protocol(
                "tool identity changed while probing".into(),
            ));
        }
        let value = ToolCatalog {
            catalog,
            supports_progress,
        };
        let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.retain(|e| {
            e.probed.elapsed() < Duration::from_secs(300) && e.identity.path != identity.path
        });
        if cache.len() >= 8 {
            cache.remove(0);
        }
        cache.push(Entry {
            identity,
            probed: Instant::now(),
            value: value.clone(),
            json_bytes: catalog_output.stdout.len(),
        });
        Ok(value)
    }
}
