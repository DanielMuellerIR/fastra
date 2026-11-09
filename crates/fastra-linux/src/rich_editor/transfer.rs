//! Begrenzte lokale Clipboard-/Drop-Daten; keine Auflösung entfernter Adressen.
use super::*;
use std::{collections::BTreeMap, path::PathBuf, sync::Arc};
pub(super) const MAX_IMAGE: usize = 32 * 1024 * 1024;
pub(super) const MAX_IMAGES: usize = 64 * 1024 * 1024;
pub(super) const MAX_PACKAGE: usize = 128 * 1024 * 1024;
pub(super) const MAX_RTF: usize = 8 * 1024 * 1024;
pub(super) const MAX_URIS: usize = 512 * 1024;
#[derive(Debug)]
pub(super) struct PackageImage {
    pub url: String,
    pub bytes: Arc<Vec<u8>>,
}
#[derive(Debug)]
pub(super) enum Transfer {
    Text(String),
    Html(String),
    Markdown {
        source: String,
        url: Option<String>,
        images: Vec<PackageImage>,
    },
    Image {
        extension: &'static str,
        bytes: Arc<Vec<u8>>,
    },
    Files(Vec<PathBuf>),
    Rtf(Vec<u8>),
}
pub(super) fn has_images(source: &str) -> bool {
    let Ok(events) = crate::markdown::syntax::events(source, &Cancellation::default()) else { return true };
    events.into_iter().any(|(event, _, _)| matches!(event,Event::Start(Tag::Image{..})) || matches!(event,Event::Html(ref raw)|Event::InlineHtml(ref raw) if raw.to_ascii_lowercase().contains("<img")))
}
pub(super) fn preferred(formats: &gtk::gdk::ContentFormats, plain: bool) -> Option<&'static str> {
    let has = |mime| formats.contain_mime_type(mime);
    if !plain {
        if has(clipboard::MIME) {
            return Some(clipboard::MIME);
        }
        if has("text/uri-list") || formats.contains_type(gtk::gdk::FileList::static_type()) {
            return Some("text/uri-list");
        }
        if has("image/png") || formats.contains_type(gtk::gdk::Texture::static_type()) {
            return Some("image/png");
        }
        for mime in [
            "image/jpeg",
            "image/gif",
            "image/webp",
            "image/tiff",
            "image/heic",
            "image/heif",
            "text/html",
            "text/rtf",
            "application/rtf",
            "application/x-rtfd",
            "text/rtfd",
            "application/rtfd",
            "com.apple.flat-rtfd",
        ] {
            if has(mime) {
                return Some(mime);
            }
        }
    }
    ["text/plain;charset=utf-8", "text/plain"]
        .into_iter()
        .find(|mime| has(mime))
        .or_else(|| {
            formats
                .contains_type(String::static_type())
                .then_some("text/plain;charset=utf-8")
        })
}
pub(super) fn limit(mime: &str) -> usize {
    match mime {
        clipboard::MIME => MAX_PACKAGE,
        "text/uri-list" => MAX_URIS,
        "text/rtf" | "application/rtf" => MAX_RTF,
        m if m.starts_with("image/") => MAX_IMAGE,
        _ => MAX_BYTES,
    }
}
fn text(bytes: &[u8]) -> Result<&str, &'static str> {
    let value = std::str::from_utf8(bytes).map_err(|_| "encoding")?;
    if value.contains('\0') {
        return Err("encoding");
    }
    Ok(value)
}
fn base64(value: &str, maximum: usize) -> Result<Vec<u8>, &'static str> {
    if value.len() > maximum.div_ceil(3) * 4 || !value.len().is_multiple_of(4) {
        return Err("size");
    }
    let content = value.trim_end_matches('=');
    if value.len() - content.len() > 2
        || !content
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/'))
    {
        return Err("format");
    }
    let bytes = glib::base64_decode(value);
    if bytes.len() > maximum {
        return Err("size");
    }
    Ok(bytes)
}
pub(super) fn decode(mime: &str, bytes: &[u8]) -> Result<Transfer, &'static str> {
    if bytes.len() > limit(mime) {
        return Err("size");
    }
    match mime {
        clipboard::MIME => {
            let value: Value = serde_json::from_slice(bytes).map_err(|_| "format")?;
            let source = value["markdown"].as_str().ok_or("format")?;
            if source.len() > MAX_BYTES || source.contains('\0') {
                return Err("size");
            }
            crate::text_limits::validate(source, Language(false)).map_err(|_| "size")?;
            if crate::markdown::syntax::events(source, &Cancellation::default()).map_err(|_| "size")?.into_iter().any(
                |(e, _, _)| matches!(e,Event::Start(Tag::Link{ref dest_url,..}) if !safe_link(dest_url)),
            ) {
                return Err("url");
            }
            let url = match value.get("url") {
                None | Some(Value::Null) => None,
                Some(Value::String(s)) if s.is_empty() => None,
                Some(Value::String(s)) => {
                    local_uri(s)?;
                    Some(s.clone())
                }
                _ => return Err("format"),
            };
            let encoded = match value.get("images") {
                None => "",
                Some(Value::String(s)) => s.as_str(),
                _ => return Err("format"),
            };
            let mut images = Vec::new();
            let mut total = 0usize;
            if !encoded.is_empty() {
                let raw = base64(encoded, 96 * 1024 * 1024)?;
                let encoded_images: BTreeMap<String, String> =
                    serde_json::from_slice(&raw).map_err(|_| "format")?;
                if encoded_images.len() > 32 {
                    return Err("size");
                }
                for (url, encoded) in encoded_images {
                    local_uri(&url)?;
                    let bytes = base64(&encoded, MAX_IMAGE)?;
                    total = total.checked_add(bytes.len()).ok_or("size")?;
                    if total > MAX_IMAGES {
                        return Err("size");
                    }
                    images.push(PackageImage {
                        url,
                        bytes: bytes.into(),
                    });
                }
            }
            Ok(Transfer::Markdown {
                source: source.into(),
                url,
                images,
            })
        }
        "text/uri-list" => {
            let value = text(bytes)?;
            let mut files = Vec::new();
            for line in value
                .lines()
                .map(|v| v.trim_end_matches('\r'))
                .filter(|v| !v.is_empty() && !v.starts_with('#'))
            {
                let path = local_uri(line)?;
                if !files.contains(&path) {
                    files.push(path);
                }
                if files.len() > 32 {
                    return Err("size");
                }
            }
            if files.is_empty() {
                return Err("format");
            }
            Ok(Transfer::Files(files))
        }
        "image/png" | "image/jpeg" | "image/gif" | "image/webp" | "image/tiff" | "image/heic"
        | "image/heif" => {
            let extension = match mime {
                "image/png" => "png",
                "image/jpeg" => "jpg",
                "image/gif" => "gif",
                "image/webp" => "webp",
                "image/heic" | "image/heif" => "heic",
                _ => "tiff",
            };
            if bytes.is_empty() {
                return Err("format");
            }
            Ok(Transfer::Image {
                extension,
                bytes: bytes.to_vec().into(),
            })
        }
        "text/rtf" | "application/rtf" => {
            if !bytes.starts_with(br"{\rtf") {
                return Err("format");
            }
            Ok(Transfer::Rtf(bytes.into()))
        }
        "application/x-rtfd" | "text/rtfd" | "application/rtfd" | "com.apple.flat-rtfd" => {
            Err("rtfd")
        }
        "text/html" => Ok(Transfer::Html(text(bytes)?.into())),
        "text/plain;charset=utf-8" | "text/plain" => Ok(Transfer::Text(text(bytes)?.into())),
        _ => Err("format"),
    }
}
pub(super) fn local_uri(value: &str) -> Result<PathBuf, &'static str> {
    if value.len() > 16384 || value.bytes().any(|b| b.is_ascii_control() || b == b' ') {
        return Err("url");
    }
    let uri = glib::Uri::parse(value, glib::UriFlags::ENCODED).map_err(|_| "url")?;
    if uri.scheme() != "file"
        || uri
            .host()
            .as_deref()
            .is_some_and(|host| !host.is_empty() && host != "localhost")
        || uri.query().is_some()
        || uri.fragment().is_some()
        || uri.userinfo().is_some()
    {
        return Err("url");
    }
    let file = gio::File::for_uri(value);
    let path = file.path().filter(|p| p.is_absolute()).ok_or("url")?;
    use std::os::unix::ffi::OsStrExt;
    if path.as_os_str().as_bytes().len() > 4096 || path.as_os_str().as_bytes().contains(&0) {
        return Err("url");
    }
    Ok(path)
}
pub(super) async fn stream(stream: gio::InputStream, mime: &str) -> Result<Transfer, &'static str> {
    let result = async {
        let maximum = limit(mime);
        let mut bytes = Vec::new();
        loop {
            let chunk = stream
                .read_bytes_future(
                    (maximum + 1 - bytes.len()).min(65536),
                    glib::Priority::DEFAULT,
                )
                .await
                .map_err(|_| "read")?;
            if chunk.is_empty() {
                break;
            }
            bytes.extend_from_slice(&chunk);
            if bytes.len() > maximum {
                return Err("size");
            }
        }
        let mime = mime.to_owned();
        gio::spawn_blocking(move || decode(&mime, &bytes))
            .await
            .map_err(|_| "read")?
    }
    .await;
    let _ = stream.close_future(glib::Priority::DEFAULT).await;
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_file_lists_preserve_paths_and_refuse_remote_whole_batches() {
        let Transfer::Files(files)=decode("text/uri-list",b"# copied\r\nfile:///private/a%23b.png\r\nfile:///private/a%23b.png\r\nfile:///private/%FF.png\r\n").unwrap()else{panic!()};
        assert_eq!(files.len(), 2);
        assert_eq!(files[0], PathBuf::from("/private/a#b.png"));
        for value in [
            "https://example.invalid/a",
            "file://remote.invalid/a",
            "file:///private/a#fragment",
            "file:///private/a?query",
            "file:///private/a%00b",
        ] {
            assert!(local_uri(value).is_err(), "{value}");
        }
        assert!(
            decode(
                "text/uri-list",
                b"file:///private/a\nhttps://example.invalid/b\n"
            )
            .is_err()
        );
    }
    #[test]
    fn private_image_packages_keep_exact_bytes_and_cannot_fetch_remote_urls() {
        let images =
            json!({"file:///source/pixel.png":glib::base64_encode(b"image bytes").to_string()})
                .to_string();
        let value=json!({"markdown":"==Marked== ![x](pixel.png)","url":"file:///source/document.md","images":glib::base64_encode(images.as_bytes()).to_string()}).to_string();
        let Transfer::Markdown { source, images, .. } =
            decode(clipboard::MIME, value.as_bytes()).unwrap()
        else {
            panic!()
        };
        assert!(source.contains("==Marked=="));
        assert_eq!(images[0].bytes.as_slice(), b"image bytes");
        assert!(decode(clipboard::MIME, br#"{"markdown":"x","images":"%%%%"}"#).is_err());
        assert!(
            decode(
                clipboard::MIME,
                br#"{"markdown":"x","url":"https://example.invalid/document.md"}"#
            )
            .is_err()
        );
        let Transfer::Text(text) = decode("text/plain", "\u{feff}NBSP\u{a0}".as_bytes()).unwrap()
        else {
            panic!()
        };
        assert_eq!(text, "\u{feff}NBSP\u{a0}");
    }
}
