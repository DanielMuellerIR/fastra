use super::*;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
pub(super) const PREFIX: &str = "fastra-rich://image/";
#[derive(Clone)]
pub(super) struct Source {
    pub raw: String,
    pub path: PathBuf,
    pub token: String,
}
#[derive(Clone, Default)]
pub(super) struct Sources(pub BTreeMap<String, Source>);
#[derive(Clone)]
pub(super) struct Image {
    pub source: Source,
    pub version: String,
    pub original: Arc<Vec<u8>>,
    pub displayed: Arc<Vec<u8>>,
    pub mime: &'static str,
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub converted: bool,
}
#[derive(Default)]
pub(super) struct Cache {
    pub images: BTreeMap<String, Image>,
    pub warnings: Vec<String>,
}
#[derive(Clone)]
struct Shared(Arc<Vec<u8>>);
impl AsRef<[u8]> for Shared {
    fn as_ref(&self) -> &[u8] {
        self.0.as_slice()
    }
}
pub(super) fn extension(path: &Path) -> Option<&'static str> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "png" => Some("png"),
        "jpg" | "jpeg" => Some("jpg"),
        "gif" => Some("gif"),
        "webp" => Some("webp"),
        "tif" | "tiff" => Some("tiff"),
        "heic" | "heif" => Some("heic"),
        _ => None,
    }
}
impl Sources {
    pub fn collect(source: &str, document: Option<&Path>, session: &str) -> Result<Self, String> {
        let mut sources = Self::default();
        let Some(document) = document else {
            return Ok(sources);
        };
        for (count, (event, _, _)) in crate::markdown::syntax::events(source, &Cancellation::default()).map_err(|_| "image source analysis limit")?.into_iter().enumerate() {
            if count > 50_000 {
                return Err("image source complexity limit".into());
            }
            if let Event::Start(Tag::Image { dest_url, .. }) = event {
                if sources.0.contains_key(dest_url.as_ref()) {
                    continue;
                }
                let Ok(path) = crate::markdown::decode_path(&dest_url) else {
                    continue;
                };
                let path = if path.is_absolute() {
                    path
                } else {
                    document
                        .parent()
                        .ok_or("document directory missing")?
                        .join(path)
                };
                if extension(&path).is_none() {
                    continue;
                }
                if sources.0.len() >= 128 || dest_url.len() > 16384 {
                    return Err("image source limit".into());
                }
                let mut hash = Sha256::new();
                hash.update(session.as_bytes());
                hash.update(document.as_os_str().as_bytes());
                hash.update(dest_url.as_bytes());
                let token = format!("{:x}", hash.finalize());
                sources.0.insert(
                    dest_url.to_string(),
                    Source {
                        raw: dest_url.to_string(),
                        path,
                        token,
                    },
                );
            }
        }
        Ok(sources)
    }
    pub fn load(&self, cancel: &crate::viewer::Cancellation) -> Cache {
        let started = Instant::now();
        let (mut cache, mut total, mut pixels) = (Cache::default(), 0usize, 0u64);
        for source in self.0.values() {
            let loaded = (|| {
                if started.elapsed() > Duration::from_secs(120) {
                    return Err("image loading deadline".into());
                }
                let path = source.path.canonicalize().map_err(|e| e.to_string())?;
                let remaining_bytes = transfer::MAX_IMAGES.saturating_sub(total);
                let remaining_pixels = 64_000_000u64.saturating_sub(pixels);
                if remaining_bytes == 0 || remaining_pixels == 0 {
                    return Err("image budget".into());
                }
                let snapshot = fastra_io::Snapshot::read_bounded(
                    &path,
                    transfer::MAX_IMAGE.min(remaining_bytes),
                    &cancel.core(),
                )
                .map_err(|e| e.to_string())?;
                let image = crate::viewer::prepare_rich_image_with_budget(
                    snapshot.bytes(),
                    extension(&path).ok_or("image format")?,
                    cancel,
                    false,
                    remaining_bytes,
                    remaining_pixels,
                )
                .map_err(|e| e.message(false))?;
                let after =
                    fastra_io::Snapshot::read_bounded(&path, transfer::MAX_IMAGE, &cancel.core())
                        .map_err(|e| e.to_string())?;
                if source.path.canonicalize().map_err(|e| e.to_string())? != path
                    || snapshot.binding_digest().map_err(|e| e.to_string())?
                        != after.binding_digest().map_err(|e| e.to_string())?
                {
                    return Err("image changed during loading".into());
                }
                total = total
                    .checked_add(snapshot.bytes().len().saturating_add(if image.converted {
                        image.bytes.len()
                    } else {
                        0
                    }))
                    .ok_or("image budget")?;
                pixels = pixels
                    .checked_add(
                        u64::from(image.width) * u64::from(image.height) * u64::from(image.frames),
                    )
                    .ok_or("image pixel budget")?;
                if total > transfer::MAX_IMAGES || pixels > 64_000_000 {
                    return Err("image budget".into());
                }
                let original: Arc<Vec<u8>> = Arc::new(snapshot.bytes().to_vec());
                let displayed = if image.converted {
                    Arc::new(image.bytes)
                } else {
                    original.clone()
                };
                Ok(Image {
                    source: source.clone(),
                    version: version(&path, snapshot.bytes()),
                    original,
                    displayed,
                    mime: match image.extension {
                        "png" => "image/png",
                        "jpg" => "image/jpeg",
                        "gif" => "image/gif",
                        "webp" => "image/webp",
                        _ => return Err("image type".into()),
                    },
                    width: image.width,
                    height: image.height,
                    frames: image.frames,
                    converted: image.converted,
                })
            })();
            match loaded {
                Ok(image) => {
                    cache.images.insert(source.token.clone(), image);
                }
                Err(error) => {
                    cache.images.insert(
                        source.token.clone(),
                        Image {
                            source: source.clone(),
                            version: String::new(),
                            original: Arc::new(Vec::new()),
                            displayed: Arc::new(Vec::new()),
                            mime: "image/png",
                            width: 0,
                            height: 0,
                            frames: 0,
                            converted: false,
                        },
                    );
                    if cache.warnings.len() < 8 {
                        cache.warnings.push(error);
                    }
                }
            }
        }
        cache
    }
}
pub(super) fn version(path: &Path, bytes: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(path.as_os_str().as_bytes());
    hash.update([0]);
    hash.update(bytes);
    format!("{:x}", hash.finalize())
}
impl Cache {
    pub fn can_extend(&self, added: &Self) -> bool {
        self.images.len().saturating_add(added.images.len()) <= 256
            && self.bytes().saturating_add(added.bytes()) <= transfer::MAX_IMAGES
            && self.pixels().saturating_add(added.pixels()) <= 64_000_000
    }
    pub fn reuse_versions(&mut self, existing: &Self, body: &mut String) {
        self.images.retain(|token, image| {
            let reusable = existing.images.iter().find(|(_, old)| {
                !image.version.is_empty()
                    && old.version == image.version
                    && old.source.raw == image.source.raw
                    && old.source.path == image.source.path
                    && old.original == image.original
                    && old.displayed == image.displayed
                    && old.mime == image.mime
                    && (old.width, old.height, old.frames, old.converted)
                        == (image.width, image.height, image.frames, image.converted)
            });
            let Some((old_token, _)) = reusable else { return true };
            // Nur die gerenderte Bildadresse ersetzen. Neue/alte Text- und
            // Opaque-Block-IDs bleiben getrennt; Undo behält seine Bildversion.
            let from = format!("src=\"{PREFIX}{token}?v={}\"", image.version);
            let to = format!("src=\"{}\"", existing.uri(old_token).unwrap());
            *body = body.replace(&from, &to);
            false
        });
    }
    pub fn uri(&self, token: &str) -> Option<String> {
        self.images.get(token).map(|image| {
            format!(
                "{PREFIX}{token}?v={}",
                if image.version.is_empty() {
                    "unavailable"
                } else {
                    &image.version
                }
            )
        })
    }
    // Bereits die erste Anzeige und jede Einfügung binden die Bytes; verspätete Kopiermeldungen dürfen keine neue Dateiversion übernehmen.
    pub fn versioned_html(&self, html: &str) -> String {
        let marker = format!("src=\"{PREFIX}");
        let mut output = String::with_capacity(html.len());
        let mut tail = html;
        while let Some(at) = tail.find(&marker) {
            output.push_str(&tail[..at]);
            tail = &tail[at + "src=\"".len()..];
            let Some(end) = tail.find('"') else {
                output.push_str("src=\"");
                output.push_str(tail);
                return output;
            };
            let uri = &tail[..end];
            output.push_str("src=\"");
            if let Some(versioned) = uri.strip_prefix(PREFIX).and_then(|token| self.uri(token)) {
                output.push_str(&versioned);
            } else {
                output.push_str(uri);
            }
            output.push('"');
            tail = &tail[end + 1..];
        }
        output.push_str(tail);
        output
    }
    pub fn lookup(&self, token: &str) -> Option<&Image> {
        let (key, requested) = token.split_once("?v=")?;
        self.images
            .get(key)
            .filter(|image| !image.version.is_empty() && requested == image.version)
    }
    pub fn bytes(&self) -> usize {
        self.images
            .values()
            .map(|image| {
                image.original.len()
                    + if image.converted {
                        image.displayed.len()
                    } else {
                        0
                    }
            })
            .sum()
    }
    pub fn pixels(&self) -> u64 {
        self.images
            .values()
            .map(|image| u64::from(image.width) * u64::from(image.height) * u64::from(image.frames))
            .sum()
    }

    pub fn serve(&self, request: &webkit6::URISchemeRequest, token: &str) {
        if let Some(image) = self.lookup(token) {
            let bytes = glib::Bytes::from_owned(Shared(image.displayed.clone()));
            let stream = gio::MemoryInputStream::from_bytes(&bytes);
            request.finish(&stream, bytes.len() as i64, Some(image.mime));
        } else {
            request.finish_error(&mut glib::Error::new(
                gio::IOErrorEnum::NotFound,
                "Image unavailable or outside verified budget",
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(token: &str, pixels: u32, bytes: Arc<Vec<u8>>) -> Image {
        Image {
            source: Source { raw: "image.png".into(), path: PathBuf::from("/image.png"), token: token.into() },
            version: version(Path::new("/image.png"), &bytes),
            original: bytes.clone(), displayed: bytes, mime: "image/png",
            width: pixels, height: 1, frames: 1, converted: false,
        }
    }
    fn cache(image: Image) -> Cache {
        Cache { images: BTreeMap::from([(image.source.token.clone(), image)]), warnings: vec![] }
    }
    #[test]
    fn combined_image_limits_cover_retained_undo_versions() {
        let bytes = Arc::new(vec![1]);
        let mut old = cache(sample("old-1", 20_000_000, bytes.clone()));
        old.images.insert("old-2".into(), sample("old-2", 20_000_000, bytes.clone()));
        let mut new = cache(sample("new-1", 20_000_000, bytes.clone()));
        new.images.insert("new-2".into(), sample("new-2", 20_000_000, bytes.clone()));
        assert!(!old.can_extend(&new), "each batch fits; combined decoded pixels do not");
        let mut full = Cache::default();
        for index in 0..256 { full.images.insert(index.to_string(), sample(&index.to_string(), 1, bytes.clone())); }
        assert!(!full.can_extend(&cache(sample("extra", 1, bytes))));
        let megabyte = Arc::new(vec![0; 1024 * 1024]);
        let mut full = Cache::default();
        for index in 0..64 { full.images.insert(index.to_string(), sample(&index.to_string(), 1, megabyte.clone())); }
        assert!(full.can_extend(&Cache::default()));
        assert!(!full.can_extend(&cache(sample("extra", 1, megabyte))));
    }
    #[test]
    fn repeated_replacements_reuse_exact_versions_but_keep_changed_bytes_for_undo() {
        let existing = cache(sample("old", 20_000_000, Arc::new(vec![1])));
        let old_uri = existing.uri("old").unwrap();
        for index in 0..300 {
            let token = format!("new-{index}");
            let mut prepared = cache(sample(&token, 20_000_000, Arc::new(vec![1])));
            let uri = prepared.uri(&token).unwrap();
            let mut body = format!("<img src=\"{uri}\" data-md-src=\"image.png\">text {uri}");
            prepared.reuse_versions(&existing, &mut body);
            assert!(prepared.images.is_empty());
            assert!(body.starts_with(&format!("<img src=\"{old_uri}\"")));
            assert!(body.ends_with(&format!("text {uri}")), "source-like text is not rewritten");
        }
        let mut changed = cache(sample("changed", 20_000_000, Arc::new(vec![2])));
        let uri = changed.uri("changed").unwrap();
        let mut body = format!("<img src=\"{uri}\">");
        changed.reuse_versions(&existing, &mut body);
        assert_eq!(changed.images.len(), 1);
        assert!(existing.can_extend(&changed));
        assert_eq!(existing.lookup(old_uri.strip_prefix(PREFIX).unwrap()).unwrap().original.as_slice(), &[1]);
        assert_eq!(body, format!("<img src=\"{uri}\">"));
    }
    #[test]
    fn delayed_image_copy_never_substitutes_new_bytes_for_the_rendered_version() {
        let source = Source {
            raw: "image.png".into(),
            path: PathBuf::from("/image.png"),
            token: "stable-source".into(),
        };
        let sources = Sources(BTreeMap::from([("image.png".into(), source.clone())]));
        let first = include_bytes!("../../tests/fixtures/pixel-1.png").to_vec();
        let second = include_bytes!("../../tests/fixtures/pixel-2.png").to_vec();
        let image = |bytes: Vec<u8>| Image {
            version: version(&source.path, &bytes),
            source: source.clone(),
            original: Arc::new(bytes.clone()),
            displayed: Arc::new(bytes),
            mime: "image/png",
            width: 1,
            height: 1,
            frames: 1,
            converted: false,
        };
        let mut cache = Cache::default();
        cache
            .images
            .insert(source.token.clone(), image(first.clone()));
        let page = super::super::page_images(
            "![Raster](image.png)",
            "fixture",
            false,
            false,
            Some(&sources),
        )
        .unwrap();
        let markup = cache.versioned_html(&page.html);
        let copied_uri = cache.uri(&source.token).unwrap();
        assert!(markup.contains(&format!("src=\"{copied_uri}\"")));
        assert!(!markup.contains(&format!("src=\"{PREFIX}{}\"", source.token)));
        assert_eq!(
            cache
                .lookup(copied_uri.strip_prefix(PREFIX).unwrap())
                .unwrap()
                .original
                .as_slice(),
            first
        );
        cache
            .images
            .insert(source.token.clone(), image(second.clone()));
        assert!(
            cache
                .lookup(copied_uri.strip_prefix(PREFIX).unwrap())
                .is_none(),
            "late native Copy must reject the old displayed version"
        );
        assert!(
            cache.lookup(&source.token).is_none(),
            "unversioned Copy must fail closed"
        );
        let current_uri = cache.uri(&source.token).unwrap();
        assert_eq!(
            cache
                .lookup(current_uri.strip_prefix(PREFIX).unwrap())
                .unwrap()
                .original
                .as_slice(),
            second
        );
    }
}
