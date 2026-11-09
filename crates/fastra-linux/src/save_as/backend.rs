use crate::{markdown, rich_editor::asset_flow, text_limits, Language};
use fastra_core::{encoding::Decoded, Cancellation};
use fastra_io::{
    markdown_assets::{Input, Owner, Plan, Receipt},
    save_target::Target,
    Snapshot,
};
use pulldown_cmark::{Event, Tag};
use std::{collections::BTreeMap, path::PathBuf, sync::Arc};
const MAX_IMAGES: usize = 64 * 1024 * 1024;
pub(super) struct Mode {
    pub markdown: bool,
    pub lang: Language,
    pub project: Option<crate::project_view::WorkBinding>,
}
impl From<bool> for Mode {
    fn from(markdown: bool) -> Self {
        Self {
            markdown,
            lang: Language(false),
            project: None,
        }
    }
}

pub(super) struct Image {
    pub requested: PathBuf,
    pub snapshot: Snapshot,
    pub destination: PathBuf,
}
pub(super) struct Prepared {
    pub source: Snapshot,
    pub target: Target,
    pub original: String,
    pub target_text: Option<String>,
    pub output: String,
    pub encoded: Vec<u8>,
    pub images: Vec<Image>,
    pub assets: Option<Plan>,
    pub owner: Owner,
    source_links: Vec<(PathBuf, PathBuf)>,
    pub relocated: bool,
    lang: Language,
    project: Option<crate::project_view::WorkBinding>,
}
pub(super) enum Outcome {
    Published {
        snapshot: Snapshot,
        content: String,
        assets: Option<Receipt>,
    },
    Failed {
        reason: String,
        target: PathBuf,
        possibly_published: bool,
        assets: Option<Receipt>,
        recovery: Vec<PathBuf>,
        journal: Option<PathBuf>,
    },
}
fn independent(value: &str) -> bool {
    value.starts_with('#')
        || ["https://", "http://", "mailto:"].iter().any(|prefix| {
            value
                .get(..prefix.len())
                .is_some_and(|value| value.eq_ignore_ascii_case(prefix))
        })
}

fn classify(source: &str, lang: Language) -> Result<(), String> {
    for (count, (event, _, _)) in markdown::syntax::events(source, &Cancellation::default()).map_err(|_| lang.text("Die Markdown-Abhängigkeiten überschreiten die Komplexitätsgrenze.", "Markdown dependency complexity limit").to_owned())?.into_iter().enumerate() {
        if count > 100_000 {
            return Err(lang
                .text(
                    "Die Markdown-Abhängigkeiten überschreiten die Komplexitätsgrenze.",
                    "Markdown dependency complexity limit",
                )
                .into());
        }
        match event {
            Event::InlineHtml(ref raw) if crate::rich_editor::relocation_safe_inline(raw) => {},
            Event::Html(_) | Event::InlineHtml(_) => {
                return Err(
                    lang.text("Rohe HTML-Abhängigkeiten können nicht sicher in einen anderen Ordner übernommen werden. Quelle erhalten.","Raw HTML dependencies cannot be safely relocated; source unchanged").into(),
                )
            }
            Event::Start(Tag::Link { dest_url, .. }) if !independent(&dest_url) => {
                let path = markdown::decode_path(&dest_url).map_err(|detail|format!("{} {dest_url}: {detail}",lang.text("Nicht unterstützte Pfadabhängigkeit:","Unsupported path dependency:")))?;
                if !path.is_absolute() {
                    return Err(format!("{} {dest_url}",lang.text("Relativer Dateilink oder Anhang kann nicht sicher umgezogen werden:","Relative non-image dependency cannot be relocated:")));
                }
            }
            _ => {}
        }
    }
    Ok(())
}
fn fragment(value: &str) -> String {
    let Some((_, fragment)) = value.split_once('#') else {
        return String::new();
    };
    let encoded = fragment
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~%".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect::<String>();
    format!("#{encoded}")
}
pub(super) fn prepare(
    source: Snapshot,
    text: String,
    format: Arc<Decoded>,
    path: PathBuf,
    mode: impl Into<Mode>,
    owner: Owner,
    cancel: &Cancellation,
) -> Result<Prepared, String> {
    let Mode {
        markdown,
        lang,
        project,
    } = mode.into();
    if let Some(project) = &project {
        project.validate()?;
    }
    source
        .verify_current(cancel)
        .map_err(|e| crate::io_error_text(lang, &e))?;
    text_limits::validate(&text, lang)?;
    let target = Target::capture(&path, cancel).map_err(|e| crate::io_error_text(lang, &e))?;
    if target.path() != source.path()
        && target
            .existing()
            .is_some_and(|existing| existing.file_identity() == source.file_identity())
    {
        return Err(lang.text("Das gewählte Ziel ist ein anderer Pfad auf dieselbe Quelldatei. Speichern verwenden oder einen unabhängigen Zielnamen wählen.","The target is another path to the same source file. Use Save or choose an independent target name.").into());
    }
    if text.len() > 4 * 1024 * 1024 {
        return Err(lang
            .text(
                "Die vollständige Speichern-unter-Vorschau ist auf 4 MiB je Textseite begrenzt.",
                "Complete Save-as preview is limited to 4 MiB per text page",
            )
            .into());
    }
    let target_text=target.existing().map(|snapshot|{
        let decoded=fastra_core::encoding::decode(snapshot.bytes(),None).map_err(|e|format!("{} {e:?}",lang.text("Das vorhandene Ziel ist nicht vollständig als Text darstellbar:","Existing target is not displayable text:")))?;
        text_limits::validate(decoded.text(),lang)?;
        if decoded.text().len()>4*1024*1024{return Err(lang.text("Das vorhandene Ziel überschreitet die vollständige Textvorschau von 4 MiB.","Existing target exceeds the complete 4 MiB text preview").into());}
        Ok::<_,String>(decoded.text().to_owned())
    }).transpose()?;
    let relocated = !target.same_parent(&source);
    let mut source_links = Vec::new();
    let mut images = Vec::new();
    let mut inputs = Vec::new();
    let mut references = Vec::new();
    let mut indices = Vec::new();
    if markdown && relocated {
        classify(&text, lang)?;
        let source_refs = asset_flow::references(&text).map_err(|detail| {
            format!(
                "{} {detail}",
                lang.text(
                    "Bildinventur konnte nicht vollständig erstellt werden:",
                    "Could not build a complete image inventory:"
                )
            )
        })?;
        let mut copied = BTreeMap::new();
        let mut remaining = MAX_IMAGES;
        for reference in source_refs {
            if independent(&reference.url) {
                continue;
            }
            let relative = markdown::decode_path(&reference.url)?;
            if relative.is_absolute() {
                continue;
            }
            // Wie der Renderer erst im Dateisystem auflösen: alias/.. darf nicht vor
            // einem Symlink verschwinden. Paketkennungen verwenden dagegen lexikalisches Matching.
            let requested = source
                .path()
                .parent()
                .ok_or("Image source directory missing")?
                .join(relative);
            if requested.as_os_str().as_encoded_bytes().len() > 4096 {
                return Err(lang
                    .text(
                        "Ein Bildpfad überschreitet die Grenze von 4096 Bytes.",
                        "Image path limit",
                    )
                    .into());
            }
            let canonical = requested
                .canonicalize()
                .map_err(|e| format!("{}: {e}", requested.display()))?;
            source_links.push((requested.clone(), canonical.clone()));
            let index = if let Some(index) = copied.get(&canonical) {
                *index
            } else {
                if images.len() >= 32 || remaining == 0 {
                    return Err(lang
                        .text(
                            "Bildgrenze erreicht: höchstens 32 Dateien mit zusammen 64 MiB.",
                            "Image batch limit",
                        )
                        .into());
                }
                let extension =
                    crate::rich_editor::raster_extension(&canonical).ok_or(lang.text(
                        "Nicht unterstützter relativer Bildtyp.",
                        "Unsupported relative image type",
                    ))?;
                let snapshot =
                    Snapshot::read_bounded(&canonical, remaining.min(32 * 1024 * 1024), cancel)
                        .map_err(|e| e.to_string())?;
                if snapshot.bytes().is_empty() {
                    return Err(lang
                        .text("Eine Bildquelle ist leer.", "Empty source image")
                        .into());
                }
                remaining -= snapshot.bytes().len();
                let index = images.len();
                inputs.push(Input {
                    extension: extension.into(),
                    bytes: Arc::new(snapshot.bytes().to_vec()),
                });
                images.push(Image {
                    requested,
                    snapshot,
                    destination: PathBuf::new(),
                });
                copied.insert(canonical, index);
                index
            };
            references.push(reference);
            indices.push(index);
        }
    }
    let assets = if inputs.is_empty() {
        None
    } else {
        Some(
            Plan::prepare_at(target.clone(), owner.clone(), inputs, cancel)
                .map_err(|e| crate::io_error_text(lang, &e))?,
        )
    };
    let mut output = text.clone();
    if let Some(plan) = &assets {
        for (image, preview) in images.iter_mut().zip(plan.preview()) {
            image.destination = target.path().parent().unwrap().join(&preview.relative);
        }
        for (reference, index) in references.iter().zip(indices).rev() {
            let relative = plan.preview()[index].relative.to_str().ok_or(lang.text(
                "Der relative Zielbildpfad ist nicht UTF-8.",
                "Image target path is not UTF-8",
            ))?;
            output.replace_range(
                reference.range.clone(),
                &asset_flow::image_link(
                    &reference.alt,
                    &format!("{relative}{}", fragment(&reference.url)),
                    &reference.title,
                ),
            );
        }
    }
    text_limits::validate(&output, lang)?;
    let encoded = format
        .encode(&output)
        .map_err(|e| crate::loader::SaveError::Encoding(e).message(lang))?;
    if encoded.len() > 32 * 1024 * 1024 {
        return Err(lang
            .text(
                "Die kodierte Zieldatei überschreitet 32 MiB.",
                "Encoded document byte limit",
            )
            .into());
    }
    Ok(Prepared {
        source_links,
        source,
        target,
        original: text,
        target_text,
        output,
        encoded,
        images,
        assets,
        owner,
        relocated: markdown && relocated,
        lang,
        project,
    })
}
impl Prepared {
    pub fn verify(&self, cancel: &Cancellation) -> Result<(), String> {
        if let Some(project) = &self.project {
            project.validate()?;
        }
        self.source
            .verify_current(cancel)
            .map_err(|e| crate::io_error_text(self.lang, &e))?;
        self.target
            .verify(cancel)
            .map_err(|e| crate::io_error_text(self.lang, &e))?;
        for (requested, canonical) in &self.source_links {
            if requested.canonicalize().map_err(|e| e.to_string())? != *canonical {
                return Err(self
                    .lang
                    .text(
                        "Ein Bildverweis wurde nach der Vorschau auf eine andere Datei umgebogen.",
                        "Image alias changed after preview",
                    )
                    .into());
            }
        }
        for image in &self.images {
            if image.requested.canonicalize().map_err(|e| e.to_string())? != image.snapshot.path() {
                return Err(self
                    .lang
                    .text(
                        "Der Bildquellpfad wurde nach der Vorschau geändert.",
                        "Image source path changed after preview",
                    )
                    .into());
            }
            image
                .snapshot
                .verify_current(cancel)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    pub fn publish(self, cancel: &Cancellation) -> Outcome {
        self.publish_with(cancel, || {})
    }
    fn publish_with(mut self, cancel: &Cancellation, after_assets: impl FnOnce()) -> Outcome {
        let target = self.target.path();
        if let Err(reason) = self.verify(cancel) {
            return Outcome::Failed {
                reason,
                target,
                possibly_published: false,
                assets: None,
                recovery: Vec::new(),
                journal: None,
            };
        }
        let receipt = match self
            .assets
            .take()
            .map(|plan| plan.apply(&self.owner, cancel))
            .transpose()
        {
            Ok(receipt) => receipt,
            Err(error) => {
                return Outcome::Failed {
                    reason: crate::io_error_text(self.lang, &error),
                    target,
                    possibly_published: false,
                    assets: None,
                    recovery: match error {
                        fastra_io::Error::RecoveryRequired(path) => vec![path],
                        _ => Vec::new(),
                    },
                    journal: None,
                }
            }
        };
        after_assets();
        if let Err(reason) = self.verify(cancel) {
            return Outcome::Failed {
                reason,
                target,
                possibly_published: false,
                assets: receipt,
                recovery: Vec::new(),
                journal: None,
            };
        }
        match self.target.publish_checked(&self.encoded, cancel) {
            Ok(snapshot) => Outcome::Published {
                snapshot,
                content: self.output,
                assets: receipt,
            },
            Err(failure) => Outcome::Failed {
                possibly_published: failure.possibly_published,
                reason: crate::io_error_text(self.lang, &failure.error),
                target,
                assets: receipt,
                recovery: match failure.error {
                    fastra_io::Error::RecoveryRequired(path) => vec![path],
                    _ => Vec::new(),
                },
                journal: failure.journal,
            },
        }
    }
}
#[cfg(test)]
mod tests;
