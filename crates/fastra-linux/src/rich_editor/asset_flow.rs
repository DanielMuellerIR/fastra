use super::*;
use fastra_io::markdown_assets::{Input, Owner, Plan};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::Arc,
};
#[derive(Clone)]
pub(super) struct Lease {
    pub owner: Owner,
    pub operation: u64,
    pub path: Option<PathBuf>,
}
impl Lease {
    pub fn capture(editor: &RichEditor) -> Option<Self> {
        let ui = editor.ui.upgrade()?;
        let doc = editor.current()?;
        Some(Self {
            owner: Owner {
                document: editor.session.clone(),
                revision: editor.revision.get(),
                generation: ui.generation.get(),
            },
            operation: editor.operation.get(),
            path: doc.disk_path(),
        })
    }
    pub fn current(&self, editor: &RichEditor) -> bool {
        editor.focused()
            && editor.session == self.owner.document
            && editor.revision.get() == self.owner.revision
            && editor.operation.get() == self.operation
            && editor
                .ui
                .upgrade()
                .is_some_and(|ui| ui.generation.get() == self.owner.generation)
            && editor
                .current()
                .is_some_and(|doc| doc.disk_path() == self.path)
    }
}
pub(super) struct Picture {
    pub bytes: Arc<Vec<u8>>,
    pub extension: &'static str,
    pub alt: String,
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub converted: bool,
    pub thumbnail: Option<crate::viewer::Raster>,
}
pub(super) struct Prepared {
    pub plan: Option<Plan>,
    pub snippet: String,
    pub pictures: Vec<Picture>,
    pub sources: images::Sources,
    pub cache: images::Cache,
    pub opens: Vec<PathBuf>,
}
pub(crate) struct Reference {
    pub range: std::ops::Range<usize>,
    pub url: String,
    pub alt: String,
    pub title: String,
}
pub(crate) fn references(source: &str) -> Result<Vec<Reference>, String> {
    let mut parser = crate::markdown::syntax::events(source, &Cancellation::default()).map_err(|_| "Markdown image analysis limit")?.into_iter();
    let mut output = Vec::new();
    let mut count = 0;
    while let Some((event, range, _)) = parser.next() {
        count += 1;
        if count > 50_000 {
            return Err("Markdown image complexity limit".into());
        }
        match event {
            Event::Start(Tag::Image {
                dest_url, title, ..
            }) => {
                let mut alt = String::new();
                for (event, _, _) in parser.by_ref() {
                    match event {
                        Event::End(TagEnd::Image) => break,
                        Event::Text(value) | Event::Code(value) => alt.push_str(&value),
                        Event::SoftBreak | Event::HardBreak => alt.push(' '),
                        Event::Start(Tag::Image { .. }) => {
                            return Err("Nested Markdown images are unsupported".into());
                        }
                        _ => {}
                    }
                }
                if output.len() >= 128 {
                    return Err("Image reference limit".into());
                }
                output.push(Reference {
                    range,
                    url: dest_url.to_string(),
                    alt,
                    title: title.to_string(),
                });
            }
            Event::Html(raw) | Event::InlineHtml(raw)
                if raw.to_ascii_lowercase().contains("<img") =>
            {
                return Err("Raw HTML image references require source mode".into());
            }
            _ => {}
        }
    }
    Ok(output)
}
fn normalized(path: &Path) -> Result<PathBuf, String> {
    let mut output = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::RootDir => output.push("/"),
            std::path::Component::Normal(value) => output.push(value),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if !output.pop() {
                    return Err("Invalid image path".into());
                }
            }
            _ => return Err("Invalid image path".into()),
        }
    }
    Ok(output)
}
pub(crate) fn resolve(raw: &str, base: Option<&Path>) -> Result<PathBuf, String> {
    let path = crate::markdown::decode_path(raw)?;
    if path.is_absolute() {
        normalized(&path)
    } else {
        normalized(
            &base
                .and_then(Path::parent)
                .ok_or("Image package has no source location")?
                .join(path),
        )
    }
}
struct BatchBudget {
    bytes: usize,
    pixels: u64,
    count: usize,
}
impl BatchBudget {
    fn new() -> Self {
        Self {
            bytes: transfer::MAX_IMAGES,
            pixels: 64_000_000,
            count: 0,
        }
    }
    fn next(&self) -> Result<(usize, u64), String> {
        if self.count >= 32 || self.bytes == 0 || self.pixels == 0 {
            return Err("Image batch limit".into());
        }
        Ok((self.bytes.min(transfer::MAX_IMAGE), self.pixels))
    }
    fn accept(&mut self, bytes: usize, pixels: u64) -> Result<(), String> {
        self.next()?;
        if bytes > self.bytes || pixels > self.pixels {
            return Err("Image batch limit".into());
        }
        self.bytes -= bytes;
        self.pixels -= pixels;
        self.count += 1;
        Ok(())
    }
}
fn picture(
    bytes: Arc<Vec<u8>>,
    extension: &str,
    alt: String,
    cancel: &crate::viewer::Cancellation,
    budget: &mut BatchBudget,
) -> Result<Picture, String> {
    let (remaining_bytes, remaining_pixels) = budget.next()?;
    let prepared = crate::viewer::prepare_rich_image_with_budget(
        bytes.as_slice(),
        extension,
        cancel,
        true,
        remaining_bytes,
        remaining_pixels,
    )
    .map_err(|e| e.message(false))?;
    budget.accept(
        prepared.bytes.len(),
        u64::from(prepared.width) * u64::from(prepared.height) * u64::from(prepared.frames),
    )?;
    Ok(Picture {
        bytes: if prepared.converted {
            Arc::new(prepared.bytes)
        } else {
            bytes
        },
        extension: prepared.extension,
        alt,
        width: prepared.width,
        height: prepared.height,
        frames: prepared.frames,
        converted: prepared.converted,
        thumbnail: prepared.thumbnail,
    })
}
fn alt(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace(['\r', '\n'], " ")
}
pub(crate) fn image_link(alt_text: &str, relative: &str, title: &str) -> String {
    let title = if title.is_empty() {
        String::new()
    } else {
        format!(" \"{}\"", title.replace('\\', "\\\\").replace('"', "\\\""))
    };
    format!("![{}](<{}>{})", alt(alt_text), relative, title)
}
pub(super) fn prepare(
    transfer: transfer::Transfer,
    lease: &Lease,
    cancel: &crate::viewer::Cancellation,
) -> Result<Prepared, String> {
    prepare_with_budget(transfer, lease, cancel, BatchBudget::new())
}
fn prepare_with_budget(
    transfer: transfer::Transfer,
    lease: &Lease,
    cancel: &crate::viewer::Cancellation,
    mut budget: BatchBudget,
) -> Result<Prepared, String> {
    let mut pictures = Vec::new();
    let mut opens = Vec::new();
    let mut source = String::new();
    let mut refs = Vec::new();
    let mut ref_picture = Vec::new();
    match transfer {
        transfer::Transfer::Image { extension, bytes } => pictures.push(picture(
            bytes,
            extension,
            "Image".into(),
            cancel,
            &mut budget,
        )?),
        transfer::Transfer::Files(paths) => {
            for path in paths {
                if let Some(extension) = images::extension(&path) {
                    let (remaining_bytes, _) = budget.next()?;
                    let canonical = path.canonicalize().map_err(|e| e.to_string())?;
                    let snapshot = fastra_io::Snapshot::read_bounded(
                        &canonical,
                        remaining_bytes,
                        &cancel.core(),
                    )
                    .map_err(|e| e.to_string())?;
                    let name = path
                        .file_stem()
                        .and_then(|v| v.to_str())
                        .unwrap_or("Image")
                        .to_owned();
                    let prepared = picture(
                        Arc::new(snapshot.bytes().to_vec()),
                        extension,
                        name,
                        cancel,
                        &mut budget,
                    )?;
                    let after = fastra_io::Snapshot::read_bounded(
                        &canonical,
                        remaining_bytes,
                        &cancel.core(),
                    )
                    .map_err(|e| e.to_string())?;
                    if path.canonicalize().map_err(|e| e.to_string())? != canonical
                        || snapshot.binding_digest().map_err(|e| e.to_string())?
                            != after.binding_digest().map_err(|e| e.to_string())?
                    {
                        return Err("Source image changed during preparation".into());
                    }
                    pictures.push(prepared);
                } else {
                    opens.push(path);
                }
            }
        }
        transfer::Transfer::Markdown {
            source: markdown,
            url,
            images,
        } => {
            source = markdown;
            refs = references(&source)?;
            let base = url
                .as_deref()
                .map(transfer::local_uri)
                .transpose()
                .map_err(str::to_owned)?;
            let mut payload = BTreeMap::new();
            for image in images {
                let key = normalized(&transfer::local_uri(&image.url).map_err(str::to_owned)?)?;
                if payload.insert(key, image.bytes).is_some() {
                    return Err("Duplicate image identity in package".into());
                }
            }
            let mut copied = BTreeMap::new();
            let mut used = BTreeSet::new();
            for reference in &refs {
                let key = resolve(&reference.url, base.as_deref())?;
                used.insert(key.clone());
                let index = if let Some(index) = copied.get(&key) {
                    *index
                } else {
                    let bytes = payload
                        .get(&key)
                        .ok_or("Image package is incomplete; no implicit file reads are allowed")?
                        .clone();
                    let extension =
                        images::extension(&key).ok_or("Unsupported package image type")?;
                    let index = pictures.len();
                    pictures.push(picture(
                        bytes,
                        extension,
                        reference.alt.clone(),
                        cancel,
                        &mut budget,
                    )?);
                    copied.insert(key, index);
                    index
                };
                ref_picture.push(index);
            }
            if used.len() != payload.len() {
                return Err("Image package contains unreferenced files; nothing discarded".into());
            }
        }
        _ => return Err("This transfer does not contain image assets".into()),
    }
    if pictures.is_empty() {
        return Ok(Prepared {
            plan: None,
            snippet: source,
            pictures,
            sources: images::Sources::default(),
            cache: images::Cache::default(),
            opens,
        });
    }
    let path = lease
        .path
        .as_deref()
        .ok_or("Save the Markdown document before inserting images")?;
    let plan = Plan::prepare(
        path,
        lease.owner.clone(),
        pictures
            .iter()
            .map(|p| Input {
                extension: p.extension.into(),
                bytes: p.bytes.clone(),
            })
            .collect(),
        &cancel.core(),
    )
    .map_err(|e| e.to_string())?;
    let relative = plan
        .preview()
        .iter()
        .map(|p| {
            p.relative
                .to_str()
                .map(str::to_owned)
                .ok_or("Asset path is not UTF-8")
        })
        .collect::<Result<Vec<_>, _>>()?;
    if refs.is_empty() {
        source = pictures
            .iter()
            .zip(&relative)
            .map(|(p, path)| image_link(&p.alt, path, ""))
            .collect::<Vec<_>>()
            .join("\n\n");
    } else {
        for (reference, index) in refs.iter().zip(ref_picture).rev() {
            source.replace_range(
                reference.range.clone(),
                &image_link(&reference.alt, &relative[index], &reference.title),
            );
        }
    }
    if source.len() > MAX_BYTES {
        return Err("Markdown result exceeds its limit".into());
    }
    let session = glib::uuid_string_random();
    let sources = images::Sources::collect(&source, Some(path), &session)?;
    let mut cache = images::Cache::default();
    for (index, p) in pictures.iter().enumerate() {
        let registered = sources
            .0
            .get(&relative[index])
            .ok_or("Image mapping missing")?;
        cache.images.insert(
            registered.token.clone(),
            images::Image {
                source: registered.clone(),
                version: images::version(&registered.path, &p.bytes),
                original: p.bytes.clone(),
                displayed: p.bytes.clone(),
                mime: match p.extension {
                    "png" => "image/png",
                    "jpg" => "image/jpeg",
                    "gif" => "image/gif",
                    "webp" => "image/webp",
                    _ => return Err("Image MIME missing".into()),
                },
                width: p.width,
                height: p.height,
                frames: p.frames,
                converted: p.converted,
            },
        );
    }
    Ok(Prepared {
        plan: Some(plan),
        snippet: source,
        pictures,
        sources,
        cache,
        opens,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn batch_budget_is_incremental_and_rejects_without_partial_accounting() {
        let mut budget = BatchBudget {
            bytes: 10,
            pixels: 3,
            count: 0,
        };
        budget.accept(6, 2).unwrap();
        assert_eq!(budget.next().unwrap(), (4, 1));
        assert!(budget.accept(5, 1).is_err());
        assert!(budget.accept(4, 2).is_err());
        assert_eq!(budget.next().unwrap(), (4, 1));
        budget.accept(4, 1).unwrap();
        assert!(budget.next().is_err());
        let mut count = BatchBudget::new();
        for _ in 0..32 {
            count.accept(1, 1).unwrap();
        }
        assert!(count.next().is_err());
    }
    #[test]
    #[ignore = "Native bounded image sandbox; isolated authorized Linux session"]
    fn file_batch_stops_before_reading_the_next_source_at_either_budget() {
        let dir = tempfile::tempdir().unwrap();
        let document = dir.path().join("document.md");
        std::fs::write(&document, "Original\n").unwrap();
        let image = dir.path().join("one.png");
        let bytes = include_bytes!("../../tests/fixtures/pixel-1.png");
        std::fs::write(&image, bytes).unwrap();
        let lease = Lease {
            owner: Owner {
                document: "budget".into(),
                revision: 1,
                generation: 1,
            },
            operation: 1,
            path: Some(document.clone()),
        };
        for budget in [
            BatchBudget {
                bytes: bytes.len(),
                pixels: 64_000_000,
                count: 0,
            },
            BatchBudget {
                bytes: transfer::MAX_IMAGES,
                pixels: 1,
                count: 0,
            },
        ] {
            // Der zweite Pfad existiert absichtlich nicht: Ein Read/Canonicalize ergäbe ENOENT statt Budgetfehler.
            let result = prepare_with_budget(
                transfer::Transfer::Files(vec![
                    image.clone(),
                    dir.path().join("must-not-read.png"),
                ]),
                &lease,
                &crate::viewer::Cancellation::default(),
                budget,
            );
            assert!(matches!(result, Err(ref error) if error == "Image batch limit"));
            assert!(!dir.path().join("images").exists());
            assert_eq!(std::fs::read(&document).unwrap(), b"Original\n");
        }
    }
    #[test]
    fn reference_ranges_preserve_neighbor_bytes_and_resolve_reference_definitions() {
        let source = "\u{feff}==Before==\r\n\r\n![a\\[b\\]](images/a%23b.png \"title\")\r\n\r\n![second][image]\r\n\r\n[image]: images/two.png\r\n";
        let refs = references(source).unwrap();
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].url, "images/a%23b.png");
        assert_eq!(refs[1].url, "images/two.png");
        let mut edited = source.to_owned();
        for reference in refs.iter().rev() {
            edited.replace_range(reference.range.clone(), "![new](images/new.png)");
        }
        assert!(edited.starts_with("\u{feff}==Before==\r\n\r\n"));
        assert!(edited.ends_with("\r\n\r\n[image]: images/two.png\r\n"));
        assert_eq!(edited.matches("![new]").count(), 2);
        let link = image_link("a[b]\\c", "images/1.png", "title\"\\");
        let parsed = references(&link).unwrap();
        assert_eq!(parsed[0].alt, "a[b]\\c");
        assert_eq!(parsed[0].title, "title\"\\");
    }
    #[test]
    fn package_locations_are_lexical_and_never_grant_implicit_file_authority() {
        assert_eq!(
            resolve(
                "../images/a%23b.png",
                Some(Path::new("/project/docs/main.md"))
            )
            .unwrap(),
            PathBuf::from("/project/images/a#b.png")
        );
        assert!(resolve(
            "https://example.invalid/a.png",
            Some(Path::new("/project/main.md"))
        )
        .is_err());
        assert!(resolve("images/a.png", None).is_err());
        assert!(references("<img src='/private/a.png'>").is_err());
    }
}
