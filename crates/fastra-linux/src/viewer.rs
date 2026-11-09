use super::{loader, Language};
use fastra_core::encoding::Encoding;
use fastra_io::ReadSnapshot;
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

const SOURCE_BYTES: usize = 32 * 1024 * 1024;
const SVG_BYTES: usize = 4 * 1024 * 1024;
const OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const OUTPUT_EDGE: u32 = 4096;
const OUTPUT_PIXELS: u64 = 16_000_000;
const INPUT_PIXELS: u64 = 32_000_000;
const MAX_PAGES: u32 = 10_000;

#[derive(Clone, Default)]
pub struct Cancellation {
    core: fastra_core::Cancellation,
    process: fastra_process::Cancellation,
}
impl Cancellation {
    pub fn cancel(&self) {
        self.core.cancel();
        self.process.cancel();
    }
    pub(super) fn core(&self) -> fastra_core::Cancellation {
        self.core.clone()
    }
    fn check(&self) -> Result<(), Error> {
        if self.process.is_cancelled() {
            Err(Error::Cancelled)
        } else {
            Ok(())
        }
    }
}
#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Snapshot(fastra_io::Error),
    Text(loader::Error),
    Missing(&'static str),
    Invalid,
    Limit,
    UnsafeSvg,
    Stale,
    Cancelled,
    Backend(String),
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<fastra_io::Error> for Error {
    fn from(e: fastra_io::Error) -> Self {
        match e {
            fastra_io::Error::Core(fastra_core::Error::Cancelled) => Self::Cancelled,
            e => Self::Snapshot(e),
        }
    }
}
impl Error {
    pub fn message(&self, de: bool) -> String {
        let lang = Language(de);
        match self {
            Self::Text(error) => error.message(de),
            Self::Snapshot(error) => super::io_error_text(lang, error),
            Self::Missing(name) => format!("{} {name}", lang.text(
                "Die sichere Vorschau benötigt das installierte Backend:",
                "Safe preview requires the installed backend:",
            )),
            Self::UnsafeSvg => lang.text(
                "SVG mit DTD, Skripten oder externen Referenzen wird nicht geöffnet. Quelldatei unverändert.",
                "SVG containing DTDs, scripts or external references is refused. Source file unchanged.",
            ).into(),
            Self::Limit => lang.text(
                "Vorschaugrenze erreicht: höchstens 32 MiB Datei (SVG 4 MiB), 32 Megapixel Bildquelle, 4096 Pixel Kantenlänge und 16 Megapixel Ausgabe.",
                "Preview limit reached: at most 32 MiB per file (SVG 4 MiB), 32 megapixels per image source, 4096 pixels per output edge and 16 megapixels per output.",
            ).into(),
            Self::Stale => lang.text(
                "Die Quelldatei wurde geändert. Neu öffnen; die alte und die neue Fassung werden nicht gemischt.",
                "The source file changed. Reopen it; old and new versions are never mixed.",
            ).into(),
            Self::Cancelled => lang.text("Vorschau abgebrochen.", "Preview cancelled.").into(),
            Self::Backend(detail) => format!("{} {}", lang.text(
                "Sichere Vorschau nicht verfügbar:", "Safe preview unavailable:",
            ), detail),
            Self::Io(error) => format!("{} ({error})", lang.text(
                "Datei konnte nicht gelesen werden.", "The file could not be read.",
            )),
            Self::Invalid => lang.text(
                "Die Datei konnte nicht als gültiges Bild, PDF oder SVG gelesen werden. Nichts verändert.",
                "The file could not be read as a valid image, PDF or SVG. Nothing changed.",
            ).into(),
        }
    }
}
pub enum Loaded {
    Editor(loader::Loaded),
    Visual(Source),
}
pub fn load(
    path: &Path,
    explicit: Option<Encoding>,
    cancel: &Cancellation,
) -> Result<Loaded, Error> {
    cancel.check()?;
    if explicit.is_none() && kind(path).is_some() {
        Source::open(path, cancel).map(Loaded::Visual)
    } else {
        (if explicit.is_none() {
            loader::read(path)
        } else {
            loader::read_with_encoding(path, explicit)
        })
        .map(Loaded::Editor)
        .map_err(Error::Text)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Image,
    Svg,
    Pdf,
}
fn kind(path: &Path) -> Option<Kind> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" => Some(Kind::Image),
        "svg" | "svgz" => Some(Kind::Svg),
        "pdf" => Some(Kind::Pdf),
        _ => None,
    }
}
#[derive(Debug, Clone, Copy)]
struct Geometry {
    width: f64,
    height: f64,
}
impl Geometry {
    fn checked(width: f64, height: f64) -> Result<Self, Error> {
        if !width.is_finite()
            || !height.is_finite()
            || width <= 0.
            || height <= 0.
            || width > 1_000_000.
            || height > 1_000_000.
        {
            return Err(Error::Invalid);
        }
        Ok(Self { width, height })
    }
    fn edge(self) -> f64 {
        self.width.max(self.height)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}
fn stamp(path: &Path) -> Result<Stamp, Error> {
    let m = fs::metadata(path)?;
    Ok(Stamp {
        device: m.dev(),
        inode: m.ino(),
        size: m.len(),
        mtime: (m.mtime(), m.mtime_nsec()),
        ctime: (m.ctime(), m.ctime_nsec()),
    })
}
#[derive(Clone)]
pub struct Source {
    snapshot: ReadSnapshot,
    requested: PathBuf,
    stamp: Stamp,
    kind: Kind,
    pages: u32,
    geometry: Geometry,
}
impl Source {
    pub(crate) fn is_pdf(&self) -> bool {
        self.kind == Kind::Pdf
    }
    pub(crate) fn page_count(&self) -> u32 {
        self.pages
    }
    pub(crate) fn render_print_page(
        &self,
        page: u32,
        cancel: &Cancellation,
    ) -> Result<Raster, Error> {
        self.render_target(page, None, Some(4000), cancel)
    }
    pub fn snapshot(&self) -> &ReadSnapshot {
        &self.snapshot
    }
    fn open(path: &Path, cancel: &Cancellation) -> Result<Self, Error> {
        cancel.check()?;
        fastra_io::check_runtime_path(path)?;
        let requested = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let resolved = requested.canonicalize()?;
        let kind = kind(path).ok_or(Error::Invalid)?;
        let snapshot = ReadSnapshot::read_bounded(&resolved, SOURCE_BYTES, &cancel.core)?;
        let current = stamp(&resolved)?;
        if current.device != snapshot.file_identity().device
            || current.inode != snapshot.file_identity().inode
            || current.size != snapshot.bytes().len() as u64
        {
            return Err(Error::Stale);
        }
        let initial = match kind {
            Kind::Svg => check_svg(snapshot.bytes())?,
            Kind::Pdf => {
                if !snapshot.bytes().starts_with(b"%PDF-") {
                    return Err(Error::Invalid);
                }
                Geometry::checked(612., 792.)?
            }
            Kind::Image => {
                image_format(snapshot.bytes())?;
                Geometry::checked(1., 1.)?
            }
        };
        let mut source = Self {
            snapshot,
            requested,
            stamp: current,
            kind,
            pages: 1,
            geometry: initial,
        };
        match kind {
            Kind::Image => {
                let sandbox = Sandbox::new(
                    source.snapshot.bytes(),
                    image_format(source.snapshot.bytes())?,
                )?;
                let output = sandbox.run_image(true, 1536, cancel)?;
                let words = std::str::from_utf8(&output)
                    .map_err(|_| Error::Invalid)?
                    .split_whitespace()
                    .collect::<Vec<_>>();
                if words.len() != 2 {
                    return Err(Error::Invalid);
                }
                let width = words[0].parse::<f64>().map_err(|_| Error::Invalid)?;
                let height = words[1].parse::<f64>().map_err(|_| Error::Invalid)?;
                source.geometry = Geometry::checked(width, height)?;
                if width * height > INPUT_PIXELS as f64 {
                    return Err(Error::Limit);
                }
            }
            Kind::Pdf => {
                let sandbox = Sandbox::new(source.snapshot.bytes(), "pdf")?;
                let info = sandbox.pdf_info(1, cancel)?;
                source.pages = info.0;
                source.geometry = info.1;
            }
            Kind::Svg => {
                backend("/usr/bin/rsvg-convert", "librsvg (rsvg-convert)")?;
                image_backend()?;
            }
        }
        source.verify(cancel)?;
        Ok(source)
    }
    fn verify(&self, cancel: &Cancellation) -> Result<(), Error> {
        cancel.check()?;
        let resolved = self.requested.canonicalize().map_err(|_| Error::Stale)?;
        if resolved != self.snapshot.path()
            || stamp(&resolved).map_err(|_| Error::Stale)? != self.stamp
        {
            return Err(Error::Stale);
        }
        let current = ReadSnapshot::read_bounded(&resolved, SOURCE_BYTES, &cancel.core)?;
        if current.file_identity() != self.snapshot.file_identity()
            || current.bytes() != self.snapshot.bytes()
        {
            return Err(Error::Stale);
        }
        Ok(())
    }
    fn render(&self, page: u32, zoom: Option<u32>, cancel: &Cancellation) -> Result<Raster, Error> {
        self.render_target(page, zoom, None, cancel)
    }
    fn render_target(
        &self,
        page: u32,
        zoom: Option<u32>,
        target_edge: Option<u32>,
        cancel: &Cancellation,
    ) -> Result<Raster, Error> {
        self.verify(cancel)?;
        if page == 0 || page > self.pages {
            return Err(Error::Invalid);
        }
        let mut geometry = self.geometry;
        let sandbox = Sandbox::new(
            self.snapshot.bytes(),
            match self.kind {
                Kind::Pdf => "pdf",
                Kind::Svg => "svg",
                Kind::Image => image_format(self.snapshot.bytes())?,
            },
        )?;
        if self.kind == Kind::Pdf {
            geometry = sandbox.pdf_info(page, cancel)?.1;
        }
        let edge = if let Some(edge) = target_edge {
            edge
        } else {
            match zoom {
                None => 1536,
                Some(percent) => {
                    if !(25..=400).contains(&percent) {
                        return Err(Error::Limit);
                    }
                    (geometry.edge() * percent as f64 / 100.).ceil() as u32
                }
            }
        };
        if edge == 0 || edge > OUTPUT_EDGE {
            return Err(Error::Limit);
        }
        match self.kind {
            Kind::Image => {
                sandbox.run_image(false, edge, cancel)?;
            }
            Kind::Pdf => {
                let executable = backend("/usr/bin/pdftoppm", "Poppler (pdftoppm/pdfinfo)")?;
                sandbox.run(
                    &executable,
                    &[
                        "-f".into(),
                        page.to_string().into(),
                        "-l".into(),
                        page.to_string().into(),
                        "-singlefile".into(),
                        "-scale-to".into(),
                        edge.to_string().into(),
                        "/input/source.pdf".into(),
                        "/output/page".into(),
                    ],
                    cancel,
                )?;
            }
            Kind::Svg => {
                let executable = backend("/usr/bin/rsvg-convert", "librsvg (rsvg-convert)")?;
                sandbox.run(
                    &executable,
                    &[
                        "--format=png".into(),
                        "--keep-aspect-ratio".into(),
                        "--width".into(),
                        edge.to_string().into(),
                        "--height".into(),
                        edge.to_string().into(),
                        "--output".into(),
                        "/output/vector.png".into(),
                        "/input/source.svg".into(),
                    ],
                    cancel,
                )?;
                let png = read_output(&sandbox.output.join("vector.png"))?;
                let image = Sandbox::new(&png, "png")?;
                image.run_image(false, edge, cancel)?;
                let raster = parse_ppm(read_output(&image.output.join("page.ppm"))?)?;
                self.verify(cancel)?;
                return Ok(raster);
            }
        }
        let raster = parse_ppm(read_output(&sandbox.output.join("page.ppm"))?)?;
        self.verify(cancel)?;
        Ok(raster)
    }
}
/// Nutzt für Rich-Assets denselben gekapselten Rasterdecoder und dieselben Speichergrenzen wie die Dateivorschau.
pub(super) struct RichImage {
    pub bytes: Vec<u8>,
    pub extension: &'static str,
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub converted: bool,
    pub thumbnail: Option<Raster>,
}
#[cfg(test)]
pub(super) fn prepare_rich_image(
    bytes: &[u8],
    extension: &str,
    cancel: &Cancellation,
    with_thumbnail: bool,
) -> Result<RichImage, Error> {
    prepare_rich_image_with_budget(
        bytes,
        extension,
        cancel,
        with_thumbnail,
        SOURCE_BYTES,
        u64::MAX,
    )
}
pub(super) fn prepare_rich_image_with_budget(
    bytes: &[u8],
    extension: &str,
    cancel: &Cancellation,
    with_thumbnail: bool,
    remaining_bytes: usize,
    remaining_pixels: u64,
) -> Result<RichImage, Error> {
    let byte_limit = remaining_bytes.min(SOURCE_BYTES);
    let pixel_limit = remaining_pixels.min(INPUT_PIXELS);
    if bytes.is_empty() || bytes.len() > byte_limit || pixel_limit == 0 {
        return Err(Error::Limit);
    }
    let format = if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        "tiff"
    } else if bytes.get(4..8) == Some(b"ftyp")
        && bytes
            .get(8..12)
            .is_some_and(|brand| matches!(brand, b"heic" | b"heix" | b"hevc" | b"hevx" | b"mif1"))
    {
        "heic"
    } else {
        image_format(bytes)?
    };
    if !match format {
        "jpeg" => matches!(extension, "jpg" | "jpeg"),
        "tiff" => matches!(extension, "tif" | "tiff"),
        "heic" => matches!(extension, "heic" | "heif"),
        _ => extension == format,
    } {
        return Err(Error::Invalid);
    }
    let sandbox = Sandbox::new(bytes, format)?;
    let magick = image_backend()?;
    let (program, args) = if magick.file_name().is_some_and(|name| name == "magick") {
        (
            magick,
            vec![
                "identify".into(),
                "-ping".into(),
                "-format".into(),
                "%w %h %W %H\n".into(),
                format!("{format}:/input/source.{format}").into(),
            ],
        )
    } else {
        (
            backend("/usr/bin/identify", "ImageMagick (identify)")?,
            vec![
                "-ping".into(),
                "-format".into(),
                "%w %h %W %H\n".into(),
                format!("{format}:/input/source.{format}").into(),
            ],
        )
    };
    let information = sandbox.run(&program, &args, cancel)?;
    let information = std::str::from_utf8(&information).map_err(|_| Error::Invalid)?;
    let (mut width, mut height, mut frames, mut pixels) = (0, 0, 0u32, 0u64);
    for line in information.lines() {
        let values = line.split_whitespace().collect::<Vec<_>>();
        if values.len() != 4 {
            return Err(Error::Invalid);
        }
        let w = values[0].parse::<u32>().map_err(|_| Error::Invalid)?;
        let h = values[1].parse::<u32>().map_err(|_| Error::Invalid)?;
        let canvas_width = values[2].parse::<u32>().map_err(|_| Error::Invalid)?;
        let canvas_height = values[3].parse::<u32>().map_err(|_| Error::Invalid)?;
        let w = w.max(canvas_width);
        let h = h.max(canvas_height);
        Geometry::checked(w.into(), h.into())?;
        frames += 1;
        pixels = pixels
            .checked_add(u64::from(w) * u64::from(h))
            .ok_or(Error::Limit)?;
        if frames > 64 || pixels > pixel_limit {
            return Err(Error::Limit);
        }
        width = width.max(w);
        height = height.max(h);
    }
    if frames == 0 {
        return Err(Error::Invalid);
    }
    if u64::from(width) * u64::from(height) * u64::from(frames) > remaining_pixels {
        return Err(Error::Limit);
    }
    let converted = matches!(format, "tiff" | "heic");
    let output = if converted {
        if frames != 1 {
            return Err(Error::Limit);
        }
        sandbox.run(
            &image_backend()?,
            &[
                "-regard-warnings".into(),
                format!("{format}:/input/source.{format}[0]").into(),
                "png:/output/asset.png".into(),
            ],
            cancel,
        )?;
        let output = read_output_bounded(&sandbox.output.join("asset.png"), byte_limit)?;
        if output.len() > SOURCE_BYTES || !output.starts_with(b"\x89PNG\r\n\x1a\n") {
            return Err(Error::Invalid);
        }
        output
    } else {
        bytes.to_vec()
    };
    let thumbnail = if with_thumbnail {
        sandbox.run_image(false, 320, cancel)?;
        Some(parse_ppm(read_output(&sandbox.output.join("page.ppm"))?)?)
    } else {
        None
    };
    Ok(RichImage {
        bytes: output,
        extension: if converted {
            "png"
        } else if format == "jpeg" {
            "jpg"
        } else {
            format
        },
        width,
        height,
        frames,
        converted,
        thumbnail,
    })
}

fn image_format(bytes: &[u8]) -> Result<&'static str, Error> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Ok("png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Ok("jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Ok("gif")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Ok("webp")
    } else {
        Err(Error::Invalid)
    }
}
fn backend(path: &str, name: &'static str) -> Result<PathBuf, Error> {
    let path = PathBuf::from(path);
    if fastra_process::host::is_active().unwrap_or(true) {
        return fastra_process::host::resolve_program(path.as_os_str())
            .map_err(|error| Error::Backend(error.to_string()))?
            .ok_or(Error::Missing(name));
    }
    if path.is_file() {
        Ok(path)
    } else {
        Err(Error::Missing(name))
    }
}
fn image_backend() -> Result<PathBuf, Error> {
    if let Ok(path) = backend("/usr/bin/magick", "ImageMagick (magick)") {
        Ok(path)
    } else {
        backend("/usr/bin/convert", "ImageMagick (magick/convert)")
    }
}
struct Sandbox {
    _directory: tempfile::TempDir,
    input: PathBuf,
    output: PathBuf,
    format: &'static str,
}
impl Sandbox {
    fn new(bytes: &[u8], format: &'static str) -> Result<Self, Error> {
        let directory = tempfile::Builder::new()
            .prefix("fastra-viewer-")
            .tempdir()?;
        let input = directory.path().join("input");
        let output = directory.path().join("output");
        fs::create_dir(&input)?;
        fs::create_dir(&output)?;
        fs::write(input.join(format!("source.{format}")), bytes)?;
        let policy=b"<policymap><policy domain=\"delegate\" rights=\"none\" pattern=\"*\"/><policy domain=\"filter\" rights=\"none\" pattern=\"*\"/><policy domain=\"coder\" rights=\"none\" pattern=\"*\"/><policy domain=\"coder\" rights=\"read|write\" pattern=\"{PNG,JPEG,GIF,WEBP,PPM}\"/><policy domain=\"resource\" name=\"memory\" value=\"128MiB\"/><policy domain=\"resource\" name=\"map\" value=\"0\"/><policy domain=\"resource\" name=\"disk\" value=\"0\"/><policy domain=\"resource\" name=\"width\" value=\"32768\"/><policy domain=\"resource\" name=\"height\" value=\"32768\"/><policy domain=\"resource\" name=\"thread\" value=\"1\"/></policymap>";
        let policy = String::from_utf8_lossy(policy);
        let policy = if matches!(format, "tiff" | "heic") {
            policy.replace(
                "{PNG,JPEG,GIF,WEBP,PPM}",
                if format == "tiff" {
                    "{PNG,JPEG,GIF,WEBP,PPM,TIFF}"
                } else {
                    "{PNG,JPEG,GIF,WEBP,PPM,HEIC}"
                },
            )
        } else {
            policy.into_owned()
        };
        fs::write(input.join("policy.xml"), policy)?;
        Ok(Self {
            _directory: directory,
            input,
            output,
            format,
        })
    }
    fn run(
        &self,
        program: &Path,
        arguments: &[OsString],
        cancel: &Cancellation,
    ) -> Result<Vec<u8>, Error> {
        cancel.check()?;
        backend("/usr/bin/bwrap", "Bubblewrap (bwrap)")?;
        let prlimit = backend("/usr/bin/prlimit", "util-linux (prlimit)")?;
        let mut args: Vec<OsString> = [
            "--as=1073741824",
            "--cpu=10",
            "--fsize=67108864",
            "--nofile=64",
            "--",
            "/usr/bin/bwrap",
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--cap-drop",
            "ALL",
            "--clearenv",
            "--setenv",
            "PATH",
            "/usr/bin",
            "--setenv",
            "LANG",
            "C.UTF-8",
            "--setenv",
            "XDG_CACHE_HOME",
            "/tmp/cache",
            "--setenv",
            "MAGICK_CONFIGURE_PATH",
            "/input",
            "--setenv",
            "OMP_NUM_THREADS",
            "1",
        ]
        .into_iter()
        .map(Into::into)
        .collect();
        for path in [
            "/usr/lib",
            "/usr/lib64",
            "/lib",
            "/lib64",
            "/usr/share/fonts",
            "/usr/share/fontconfig",
            "/usr/share/poppler",
            "/etc/fonts",
            "/etc/ld.so.cache",
            "/var/cache/fontconfig",
        ] {
            if Path::new(path).exists() {
                args.extend(["--ro-bind".into(), path.into(), path.into()]);
            }
        }
        args.extend([
            "--dir".into(),
            "/usr/bin".into(),
            "--ro-bind".into(),
            program.as_os_str().to_owned(),
            program.as_os_str().to_owned(),
            "--ro-bind".into(),
            self.input.as_os_str().to_owned(),
            "/input".into(),
            "--bind".into(),
            self.output.as_os_str().to_owned(),
            "/output".into(),
            "--proc".into(),
            "/proc".into(),
            "--dev".into(),
            "/dev".into(),
            "--tmpfs".into(),
            "/tmp".into(),
            "--chdir".into(),
            "/input".into(),
            "--".into(),
            program.as_os_str().to_owned(),
        ]);
        args.extend_from_slice(arguments);
        let environment = fastra_process::Environment {
            remove_prefixes: vec!["LD_".into(), "GCONV_PATH".into()],
            set: Vec::new(),
        };
        let result = fastra_process::run(
            &prlimit,
            self._directory.path(),
            &args,
            fastra_process::Policy {
                timeout: Duration::from_secs(15),
                stdout_bytes: 64 * 1024,
                stderr_bytes: 16 * 1024,
                ..Default::default()
            },
            &cancel.process,
            &environment,
        )
        .map_err(|e| match e {
            fastra_process::Error::Cancelled(_) => Error::Cancelled,
            other => Error::Backend(other.to_string()),
        })?;
        if !result.success() {
            return Err(Error::Backend(
                String::from_utf8_lossy(&result.stderr)
                    .replace('\0', "�")
                    .chars()
                    .take(1600)
                    .collect(),
            ));
        }
        Ok(result.stdout)
    }
    fn run_image(&self, info: bool, edge: u32, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
        cancel.check()?;
        let magick = image_backend()?;
        let mut args = Vec::new();
        if info {
            if magick.file_name().is_some_and(|name| name == "magick") {
                args.push("identify".into())
            } else {
                let identify = backend("/usr/bin/identify", "ImageMagick (identify)")?;
                return self.run(
                    &identify,
                    &[
                        "-ping".into(),
                        "-format".into(),
                        "%w %h".into(),
                        format!("{}:/input/source.{}[0]", self.format, self.format).into(),
                    ],
                    cancel,
                );
            }
            args.extend([
                "-ping".into(),
                "-format".into(),
                "%w %h".into(),
                format!("{}:/input/source.{}[0]", self.format, self.format).into(),
            ]);
        } else {
            args.extend([
                "-regard-warnings".into(),
                format!("{}:/input/source.{}[0]", self.format, self.format).into(),
                "-auto-orient".into(),
                "-resize".into(),
                format!("{edge}x{edge}").into(),
                "-background".into(),
                "#ffffff".into(),
                "-alpha".into(),
                "remove".into(),
                "-depth".into(),
                "8".into(),
                "ppm:/output/page.ppm".into(),
            ]);
        }
        self.run(&magick, &args, cancel)
    }
    fn pdf_info(&self, page: u32, cancel: &Cancellation) -> Result<(u32, Geometry), Error> {
        let pdfinfo = backend("/usr/bin/pdfinfo", "Poppler (pdftoppm/pdfinfo)")?;
        let output = self.run(
            &pdfinfo,
            &[
                "-f".into(),
                page.to_string().into(),
                "-l".into(),
                page.to_string().into(),
                "-box".into(),
                "/input/source.pdf".into(),
            ],
            cancel,
        )?;
        let text = std::str::from_utf8(&output).map_err(|_| Error::Invalid)?;
        let pages = text
            .lines()
            .filter_map(|line| line.strip_prefix("Pages:"))
            .next_back()
            .ok_or(Error::Invalid)?
            .trim()
            .parse::<u32>()
            .map_err(|_| Error::Invalid)?;
        if pages == 0 || pages > MAX_PAGES {
            return Err(Error::Limit);
        }
        let geometry = text
            .lines()
            .filter_map(|line| {
                let words = line.split_whitespace().collect::<Vec<_>>();
                if words.len() >= 6
                    && words[0] == "Page"
                    && words[1] == page.to_string()
                    && words[2] == "size:"
                {
                    Some((words[3].parse::<f64>(), words[5].parse::<f64>()))
                } else {
                    None
                }
            })
            .next_back()
            .ok_or(Error::Invalid)?;
        Ok((
            pages,
            Geometry::checked(
                geometry.0.map_err(|_| Error::Invalid)? * 96. / 72.,
                geometry.1.map_err(|_| Error::Invalid)? * 96. / 72.,
            )?,
        ))
    }
}
fn read_output(path: &Path) -> Result<Vec<u8>, Error> {
    read_output_bounded(path, OUTPUT_BYTES)
}
fn read_output_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, Error> {
    let directory = path.parent().ok_or(Error::Invalid)?;
    let metadata = fs::symlink_metadata(directory)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(Error::Invalid);
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return Err(Error::Limit);
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(Error::Limit);
    }
    Ok(bytes)
}
pub(crate) struct Raster {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) rgb: Vec<u8>,
}
// Unvertrauenswürdige Codecs bleiben im Kindprozess; GTK erhält nur begrenzte RGB-Pixel.
fn parse_ppm(bytes: Vec<u8>) -> Result<Raster, Error> {
    let mut cursor = 0;
    let mut tokens = Vec::new();
    while tokens.len() < 4 {
        while bytes.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
            if cursor > 4096 {
                return Err(Error::Invalid);
            }
        }
        if bytes.get(cursor) == Some(&b'#') {
            while bytes.get(cursor).is_some_and(|b| *b != b'\n') {
                cursor += 1;
                if cursor > 4096 {
                    return Err(Error::Invalid);
                }
            }
            continue;
        }
        let start = cursor;
        while bytes.get(cursor).is_some_and(|b| !b.is_ascii_whitespace()) {
            cursor += 1;
            if cursor > 4096 {
                return Err(Error::Invalid);
            }
        }
        if cursor == start {
            return Err(Error::Invalid);
        }
        tokens.push(std::str::from_utf8(&bytes[start..cursor]).map_err(|_| Error::Invalid)?);
    }
    if tokens[0] != "P6" || tokens[3] != "255" {
        return Err(Error::Invalid);
    }
    let width = tokens[1].parse::<u32>().map_err(|_| Error::Invalid)?;
    let height = tokens[2].parse::<u32>().map_err(|_| Error::Invalid)?;
    if width == 0
        || height == 0
        || width > OUTPUT_EDGE
        || height > OUTPUT_EDGE
        || u64::from(width) * u64::from(height) > OUTPUT_PIXELS
    {
        return Err(Error::Limit);
    }
    if !bytes.get(cursor).is_some_and(u8::is_ascii_whitespace) {
        return Err(Error::Invalid);
    }
    cursor += 1;
    let expected = width as usize * height as usize * 3;
    if bytes.len() - cursor != expected {
        return Err(Error::Invalid);
    }
    Ok(Raster {
        width,
        height,
        rgb: bytes[cursor..].to_vec(),
    })
}
fn check_svg(bytes: &[u8]) -> Result<Geometry, Error> {
    if bytes.len() > SVG_BYTES {
        return Err(Error::Limit);
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error::Invalid)?
        .trim_start_matches('\u{feff}');
    if text.to_ascii_lowercase().contains("<!doctype")
        || text.to_ascii_lowercase().contains("<!entity")
    {
        return Err(Error::UnsafeSvg);
    }
    let doc = roxmltree::Document::parse_with_options(
        text,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: 100_000,
            entity_resolver: None,
        },
    )
    .map_err(|_| Error::UnsafeSvg)?;
    let root = doc.root_element();
    if root.tag_name().name() != "svg" {
        return Err(Error::Invalid);
    }
    for node in doc.descendants() {
        if node.is_pi() {
            return Err(Error::UnsafeSvg);
        }
        if !node.is_element() {
            continue;
        }
        if matches!(
            node.tag_name().name(),
            "script" | "foreignObject" | "include"
        ) {
            return Err(Error::UnsafeSvg);
        }
        for attr in node.attributes() {
            if matches!(attr.name(), "href" | "src") && !attr.value().trim().starts_with('#') {
                return Err(Error::UnsafeSvg);
            }
            if attr.name() == "base"
                && attr.namespace() == Some("http://www.w3.org/XML/1998/namespace")
            {
                return Err(Error::UnsafeSvg);
            }
            if matches!(
                attr.name(),
                "style"
                    | "fill"
                    | "stroke"
                    | "filter"
                    | "clip-path"
                    | "mask"
                    | "marker-start"
                    | "marker-mid"
                    | "marker-end"
                    | "cursor"
                    | "color-profile"
            ) {
                check_css(attr.value())?
            }
        }
        if node.tag_name().name() == "style" {
            for child in node.children().filter(|n| n.is_text()) {
                check_css(child.text().unwrap_or(""))?
            }
        }
    }
    let dimension = |name| {
        root.attribute(name)
            .and_then(|v| v.strip_suffix("px").unwrap_or(v).parse::<f64>().ok())
    };
    if let (Some(w), Some(h)) = (dimension("width"), dimension("height")) {
        return Geometry::checked(w, h);
    }
    if let Some(value) = root.attribute("viewBox") {
        let values = value
            .split(|c: char| c.is_ascii_whitespace() || c == ',')
            .filter(|s| !s.is_empty())
            .map(str::parse::<f64>)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| Error::Invalid)?;
        if values.len() == 4 {
            return Geometry::checked(values[2], values[3]);
        }
    }
    Geometry::checked(300., 150.)
}
fn check_css(css: &str) -> Result<(), Error> {
    if css.contains(['\\', '@']) {
        return Err(Error::UnsafeSvg);
    }
    let compact = css
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    let mut rest = compact.as_str();
    while let Some(start) = rest.find("url(") {
        rest = &rest[start + 4..];
        let end = rest.find(')').ok_or(Error::UnsafeSvg)?;
        let value = rest[..end].trim_matches(['\'', '"']);
        if !value.starts_with('#') {
            return Err(Error::UnsafeSvg);
        }
        rest = &rest[end + 1..];
    }
    Ok(())
}

use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::mpsc,
};
pub struct Viewer {
    pub root: gtk::Box,
    source: Source,
    language: Language,
    picture: gtk::Picture,
    status: gtk::Label,
    page: gtk::SpinButton,
    previous: gtk::Button,
    next: gtk::Button,
    zoom: gtk::DropDown,
    busy: Cell<bool>,
    generation: Cell<u64>,
    cancellation: RefCell<Cancellation>,
    owner: Rc<dyn Fn() -> bool>,
}
impl Viewer {
    pub(crate) fn after_git_attempt(&self) {
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.busy.set(false);
        self.controls();
        self.status.set_text(self.language.text("Git-Wechsel versucht. Bisherige Vorschau erhalten; für den aktuellen Dateistand neu öffnen.", "Git switch attempted. Previous preview retained; reopen for current file contents."));
    }
    pub(crate) fn disk_path(&self) -> PathBuf {
        self.source.snapshot.path()
    }
    pub(crate) fn print_source(&self) -> Source {
        self.source.clone()
    }
    pub fn new(
        source: Source,
        language: Language,
        owner: Rc<dyn Fn() -> bool>,
        reopen: Rc<dyn Fn()>,
    ) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.set_vexpand(true);
        let title = gtk::Label::new(Some(&format!(
            "{} · {}",
            match source.kind {
                Kind::Pdf => "PDF",
                Kind::Svg => "SVG",
                Kind::Image => language.text("Bild", "Image"),
            },
            language.text(
                "schreibgeschützte Vorschau · Quelldatei unverändert",
                "read-only preview · source file unchanged"
            )
        )));
        title.set_xalign(0.);
        title.set_wrap(true);
        title.add_css_class("heading");
        root.append(&title);
        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let previous = gtk::Button::with_label(language.text("Zurück", "Previous"));
        let next = gtk::Button::with_label(language.text("Weiter", "Next"));
        controls.append(&previous);
        controls.append(&next);
        controls.append(&gtk::Label::new(Some(language.text("Seite", "Page"))));
        let page = gtk::SpinButton::with_range(1., source.pages as f64, 1.);
        page.set_value(1.);
        page.set_width_chars(4);
        page.set_sensitive(source.pages > 1);
        controls.append(&page);
        controls.append(&gtk::Label::new(Some(&format!("/ {}", source.pages))));
        let zoom = gtk::DropDown::from_strings(&[
            language.text("Einpassen", "Fit"),
            "25 %",
            "50 %",
            "75 %",
            "100 %",
            "150 %",
            "200 %",
            "300 %",
            "400 %",
        ]);
        controls.append(&zoom);
        let fit = gtk::Button::with_label(language.text("Einpassen", "Fit"));
        controls.append(&fit);
        let reload = gtk::Button::with_label(language.text("Neu öffnen", "Reopen"));
        reload.set_tooltip_text(Some(language.text(
            "Öffnet den aktuellen Dateistand in einem neuen Tab.",
            "Opens the current file in a new tab.",
        )));
        reload.connect_clicked(move |_| reopen());
        controls.append(&reload);
        root.append(&controls);
        let status = gtk::Label::new(None);
        status.set_xalign(0.);
        status.set_wrap(true);
        root.append(&status);
        let picture = gtk::Picture::new();
        picture.set_can_shrink(true);
        picture.set_content_fit(gtk::ContentFit::Contain);
        picture.set_hexpand(true);
        picture.set_vexpand(true);
        let scroll = gtk::ScrolledWindow::builder()
            .child(&picture)
            .hexpand(true)
            .vexpand(true)
            .min_content_height(160)
            .build();
        scroll.add_css_class("frame");
        root.append(&scroll);
        let view = Rc::new(Self {
            root,
            source,
            language,
            picture,
            status,
            page,
            previous,
            next,
            zoom,
            busy: Cell::new(false),
            generation: Cell::new(0),
            cancellation: RefCell::new(Cancellation::default()),
            owner,
        });
        let weak = Rc::downgrade(&view);
        view.previous.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.page.set_value(view.page.value() - 1.)
            }
        });
        let weak = Rc::downgrade(&view);
        view.next.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.page.set_value(view.page.value() + 1.)
            }
        });
        let weak = Rc::downgrade(&view);
        view.page.connect_value_changed(move |_| {
            if let Some(view) = weak.upgrade() {
                view.request()
            }
        });
        let weak = Rc::downgrade(&view);
        view.zoom.connect_selected_notify(move |_| {
            if let Some(view) = weak.upgrade() {
                view.request()
            }
        });
        let weak = Rc::downgrade(&view);
        fit.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                if view.zoom.selected() == 0 {
                    view.request()
                } else {
                    view.zoom.set_selected(0)
                }
            }
        });
        view.request();
        view
    }
    fn controls(&self) {
        self.previous
            .set_sensitive(!self.busy.get() && self.page.value() > 1.);
        self.next
            .set_sensitive(!self.busy.get() && self.page.value() < self.source.pages as f64);
        self.page
            .set_sensitive(!self.busy.get() && self.source.pages > 1);
        self.zoom.set_sensitive(!self.busy.get());
    }
    fn request(self: &Rc<Self>) {
        self.cancellation.borrow().cancel();
        if !(self.owner)() {
            return;
        }
        let cancel = Cancellation::default();
        *self.cancellation.borrow_mut() = cancel.clone();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.busy.set(true);
        self.controls();
        let source = self.source.clone();
        let page = self.page.value_as_int() as u32;
        let selected = self.zoom.selected();
        let zoom = if selected == 0 {
            None
        } else {
            [25, 50, 75, 100, 150, 200, 300, 400]
                .get(selected as usize - 1)
                .copied()
        };
        self.status.set_text(self.language.text(
            "Sichere Vorschau wird berechnet …",
            "Rendering safe preview …",
        ));
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(source.render(page, zoom, &cancel));
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(view) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if view.generation.get() != generation {
                return glib::ControlFlow::Break;
            }
            if !(view.owner)() {
                view.cancellation.borrow().cancel();
                view.busy.set(false);
                view.status.set_text(view.language.text(
                    "Vorschau pausiert. Einpassen lädt diesen Tab erneut.",
                    "Preview paused. Fit reloads this tab.",
                ));
                view.controls();
                return glib::ControlFlow::Break;
            }
            match rx.try_recv() {
                Ok(Ok(raster)) => {
                    view.busy.set(false);
                    let width = raster.width;
                    let height = raster.height;
                    let texture = gtk::gdk::MemoryTexture::new(
                        width as i32,
                        height as i32,
                        gtk::gdk::MemoryFormat::R8g8b8,
                        &glib::Bytes::from_owned(raster.rgb),
                        width as usize * 3,
                    );
                    view.picture.set_can_shrink(selected == 0);
                    if selected == 0 {
                        view.picture.set_size_request(-1, -1)
                    } else {
                        view.picture.set_size_request(width as i32, height as i32)
                    }
                    view.picture.set_paintable(Some(&texture));
                    view.status.set_text(&format!(
                        "{} {} / {} · {} × {} {}",
                        view.language.text("Seite", "Page"),
                        page,
                        view.source.pages,
                        width,
                        height,
                        view.language.text(
                            "Pixel · Transparenz auf Weiß",
                            "pixels · transparency on white"
                        )
                    ));
                    view.controls();
                    glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    view.busy.set(false);
                    view.picture.set_paintable(None::<&gtk::gdk::Paintable>);
                    view.status.set_text(&error.message(view.language.0));
                    view.controls();
                    glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => {
                    view.busy.set(false);
                    view.picture.set_paintable(None::<&gtk::gdk::Paintable>);
                    view.status.set_text(view.language.text(
                        "Vorschau wurde unerwartet beendet. Neu öffnen.",
                        "Preview ended unexpectedly. Reopen the file.",
                    ));
                    view.controls();
                    glib::ControlFlow::Break
                }
            }
        });
    }
}
impl Drop for Viewer {
    fn drop(&mut self) {
        self.cancellation.borrow().cancel();
    }
}

#[cfg(any(test, debug_assertions))]
fn sample_pdf() -> Vec<u8> {
    let streams = [
        "1 0 0 rg 20 20 100 80 re f BT /F1 24 Tf 30 150 Td (PAGE ONE) Tj ET",
        "0 0 1 rg 100 30 160 90 re f BT /F1 24 Tf 30 150 Td (PAGE TWO) Tj ET",
    ];
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
        "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>".to_owned(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>".to_owned(),
        format!("<< /Length {} >>\nstream\n{}\nendstream", streams[0].len(), streams[0]),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>".to_owned(),
        format!("<< /Length {} >>\nstream\n{}\nendstream", streams[1].len(), streams[1]),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_owned(),
    ];
    let mut bytes = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (index, object) in objects.iter().enumerate() {
        offsets.push(bytes.len());
        bytes.extend(format!("{} 0 obj\n{}\nendobj\n", index + 1, object).as_bytes());
    }
    let start = bytes.len();
    bytes.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
    for offset in offsets {
        bytes.extend(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    bytes
}

#[cfg(debug_assertions)]
fn capture(
    window: &gtk::ApplicationWindow,
    name: &str,
    state: &RefCell<Option<mpsc::Receiver<bool>>>,
) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_VIEWER_SCREENSHOTS") else {
        return true;
    };
    let pending = state.borrow().as_ref().map(mpsc::Receiver::try_recv);
    if let Some(result) = pending {
        match result {
            Ok(success) => assert!(success, "Viewer screenshot failed"),
            Err(mpsc::TryRecvError::Empty) => return false,
            Err(_) => panic!("Screenshot worker stopped"),
        }
    } else {
        let directory = PathBuf::from(directory);
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join(format!("{name}.png"));
        let (tx, rx) = mpsc::channel();
        *state.borrow_mut() = Some(rx);
        let job = RefCell::new(Some((path, tx)));
        let clock = window.frame_clock().unwrap();
        clock.connect_after_paint(move |_| {
            let Some((path, tx)) = job.borrow_mut().take() else {
                return;
            };
            std::thread::spawn(move || {
                let success = std::process::Command::new("xdotool")
                    .args([
                        "search",
                        "--onlyvisible",
                        "--pid",
                        &std::process::id().to_string(),
                    ])
                    .output()
                    .ok()
                    .filter(|o| o.status.success())
                    .and_then(|o| String::from_utf8(o.stdout).ok())
                    .and_then(|ids| ids.lines().next().map(str::to_owned))
                    .is_some_and(|id| {
                        std::process::Command::new("import")
                            .args(["-silent", "-window", &id])
                            .arg(path)
                            .status()
                            .is_ok_and(|s| s.success())
                    });
                let _ = tx.send(success);
            });
        });
        window.queue_draw();
        clock.request_phase(gtk::gdk::FrameClockPhase::PAINT);
        return false;
    }
    state.borrow_mut().take();
    true
}

#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<super::Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_VIEWER_WIDTH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1180);
    let height = std::env::var("FASTRA_VIEWER_HEIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(850);
    ui.window.set_default_size(width, height);
    let directory = tempfile::Builder::new()
        .prefix("fastra-viewer-ui-")
        .tempdir()
        .unwrap();
    let png = directory.path().join("pixel.png");
    let png_bytes = include_bytes!("../tests/fixtures/pixel-1.png");
    fs::write(&png, png_bytes).unwrap();
    let svg = directory.path().join("shapes.svg");
    let svg_bytes=br##"<svg xmlns="http://www.w3.org/2000/svg" width="600" height="360"><rect width="600" height="360" fill="#f8f8ff"/><rect x="40" y="50" width="200" height="180" rx="20" fill="#17845b"/><circle cx="400" cy="150" r="90" fill="#2b63b4"/><text x="50" y="310" font-size="34">Native SVG preview</text></svg>"##;
    fs::write(&svg, svg_bytes).unwrap();
    let pdf = directory.path().join("two-pages.pdf");
    let pdf_bytes = sample_pdf();
    fs::write(&pdf, &pdf_bytes).unwrap();
    for path in [&png, &svg, &pdf] {
        fs::hard_link(path, path.with_extension("linked-source")).unwrap();
        assert!(matches!(fastra_io::Snapshot::read(path, &fastra_core::Cancellation::default()), Err(fastra_io::Error::UnsupportedMetadata)));
    }
    let unsafe_svg = directory.path().join("external.svg");
    fs::write(
        &unsafe_svg,
        br#"<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///etc/passwd"/></svg>"#,
    )
    .unwrap();
    let stage = Cell::new(0);
    let captures = RefCell::new(None);
    let paused_view = RefCell::new(None::<Rc<Viewer>>);
    let saved_page = Cell::new(0);
    let pages = Cell::new(0);
    let started = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(90),
            "Viewer UI stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let current = || ui.active().unwrap();
        let active = || current().visual_view.borrow().clone();
        match stage.get() {
            0 => {
                ui.load_path(png.clone());
                stage.set(1)
            }
            1 => {
                if current().name != "pixel.png" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = active() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                assert!(current().is_read_only());
                assert!(current().buffer.char_count() == 0);
                assert!(!ui.save.is_sensitive());
                ui.save_document();
                assert_eq!(fs::read(&png).unwrap(), png_bytes);
                if !capture(&ui.window, "image-fit", &captures) {
                    return glib::ControlFlow::Continue;
                }
                ui.load_path(svg.clone());
                stage.set(2)
            }
            2 => {
                if current().name != "shapes.svg" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = active() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                view.zoom.set_selected(6);
                stage.set(3)
            }
            3 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                if !capture(&ui.window, "svg-zoom", &captures) {
                    return glib::ControlFlow::Continue;
                }
                view.zoom.set_selected(0);
                stage.set(4)
            }
            4 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some());
                assert_eq!(fs::read(&svg).unwrap(), svg_bytes);
                if !capture(&ui.window, "svg-fit", &captures) {
                    return glib::ControlFlow::Continue;
                }
                saved_page.set(ui.tabs.current_page().unwrap());
                *paused_view.borrow_mut() = Some(view.clone());
                view.request();
                ui.tabs.set_current_page(Some(0));
                stage.set(11)
            }
            5 => {
                if ui
                    .status
                    .text()
                    .contains(ui.lang.text("SVG mit", "SVG containing"))
                {
                    assert_eq!(ui.tabs.n_pages(), pages.get());
                    ui.load_path(pdf.clone());
                    stage.set(6)
                }
            }
            6 => {
                if current().name != "two-pages.pdf" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = active() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.source.pages, 2);
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                view.next.emit_clicked();
                stage.set(7)
            }
            7 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.page.value_as_int(), 2);
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                view.zoom.set_selected(6);
                stage.set(8)
            }
            8 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                if !capture(&ui.window, "pdf-page2-zoom", &captures) {
                    return glib::ControlFlow::Continue;
                }
                view.zoom.set_selected(0);
                stage.set(9)
            }
            9 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some());
                assert_eq!(fs::read(&pdf).unwrap(), pdf_bytes);
                if !capture(&ui.window, "pdf-page2-fit", &captures) {
                    return glib::ControlFlow::Continue;
                }
                let replacement = directory.path().join("replacement");
                fs::write(&replacement, &pdf_bytes).unwrap();
                fs::rename(replacement, &pdf).unwrap();
                view.request();
                stage.set(10)
            }
            10 => {
                let view = active().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_none());
                assert!(
                    view.status.text().contains(
                        ui.lang
                            .text("Quelldatei wurde geändert", "source file changed")
                    )
                );
                if !capture(&ui.window, "pdf-stale", &captures) {
                    return glib::ControlFlow::Continue;
                }
                println!(
                    "PASS native viewer GTK: image/SVG/PDF read-only, page2, zoom/fit, external SVG refused, exact source preservation, owner cancellation/resume and same-byte replacement rejected"
                );
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            11 => {
                let view = paused_view.borrow().clone().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    view.status
                        .text()
                        .contains(ui.lang.text("Vorschau pausiert", "Preview paused"))
                );
                ui.tabs.set_current_page(Some(saved_page.get()));
                view.request();
                stage.set(12)
            }
            12 => {
                let view = paused_view.borrow().clone().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.picture.paintable().is_some(), "{}", view.status.text());
                pages.set(ui.tabs.n_pages());
                ui.load_path(unsafe_svg.clone());
                stage.set(5)
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn svg_rejects_decoded_external_references_and_active_content() {
        for text in [
            r##"<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///etc/passwd"/></svg>"##,
            r##"<svg xmlns="http://www.w3.org/2000/svg"><image href="&#104;ttps://example.invalid/x"/></svg>"##,
            r##"<svg xmlns="http://www.w3.org/2000/svg"><style>@import "x";</style></svg>"##,
            r##"<svg xmlns="http://www.w3.org/2000/svg"><path fill="url(http://example.invalid)"/></svg>"##,
            r##"<svg xmlns="http://www.w3.org/2000/svg" xml:base="file:///etc/"><use href="#x"/></svg>"##,
            r##"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>"##,
            r##"<svg><script/></svg>"##,
        ] {
            assert!(
                matches!(check_svg(text.as_bytes()), Err(Error::UnsafeSvg)),
                "{text}"
            )
        }
    }
    #[test]
    fn svg_allows_local_paths_and_fragments() {
        let data=br##"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160"><defs><linearGradient id="a"/></defs><rect width="240" height="160" fill="url(#a)"/></svg>"##;
        let geometry = check_svg(data).unwrap();
        assert_eq!(geometry.width, 240.);
        assert_eq!(geometry.height, 160.);
        assert!(check_css(r"u\72l(file:///etc/passwd)").is_err());
    }
    #[test]
    fn ppm_bytes_never_reach_a_parent_codec() {
        let mut bytes = b"P6\n2 1\n255\n".to_vec();
        bytes.extend([255, 0, 0, 0, 255, 0]);
        let raster = parse_ppm(bytes).unwrap();
        assert_eq!((raster.width, raster.height), (2, 1));
        assert_eq!(raster.rgb, [255, 0, 0, 0, 255, 0]);
        assert!(parse_ppm(b"P6\n999999 999999\n255\n".to_vec()).is_err());
        assert!(parse_ppm(b"P6\n2 1\n255\nabc".to_vec()).is_err());
    }
    #[test]
    fn output_symlinks_are_never_followed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("page.ppm");
        std::os::unix::fs::symlink("/etc/passwd", &path).unwrap();
        assert!(read_output(&path).is_err());
    }
    #[test]
    fn cancelled_render_never_launches_a_backend() {
        let cancel = Cancellation::default();
        cancel.cancel();
        let sandbox = Sandbox::new(b"test", "png").unwrap();
        assert!(matches!(
            sandbox.run_image(false, 100, &cancel),
            Err(Error::Cancelled)
        ));
    }

    #[test]
    #[ignore = "Real native parser and user-namespace test; run on an isolated authorized Linux session"]
    fn real_native_backends_and_isolation() {
        let directory = tempfile::tempdir().unwrap();
        let cancel = Cancellation::default();
        let png = directory.path().join("pixel.png");
        let png_bytes = include_bytes!("../tests/fixtures/pixel-1.png");
        fs::write(&png, png_bytes).unwrap();
        let image = Source::open(&png, &cancel).unwrap();
        let raster = image.render(1, Some(100), &cancel).unwrap();
        assert_eq!((raster.width, raster.height), (1, 1));
        assert_eq!(fs::read(&png).unwrap(), png_bytes);
        for extension in ["jpeg", "gif", "webp"] {
            let path = directory.path().join(format!("pixel.{extension}"));
            assert!(
                std::process::Command::new(image_backend().unwrap())
                    .arg(&png)
                    .arg(&path)
                    .status()
                    .unwrap()
                    .success()
            );
            let source = Source::open(&path, &cancel).unwrap();
            let raster = source.render(1, Some(100), &cancel).unwrap();
            assert_eq!((raster.width, raster.height), (1, 1));
        }
        let link = directory.path().join("linked.png");
        std::os::unix::fs::symlink(&png, &link).unwrap();
        let linked = Source::open(&link, &cancel).unwrap();
        assert!(linked.render(1, Some(100), &cancel).is_ok());
        let invalid = directory.path().join("invalid.pdf");
        fs::write(&invalid, "ordinary text").unwrap();
        assert!(matches!(load(&invalid, None, &cancel), Err(Error::Invalid)));
        let large = directory.path().join("large.pdf");
        fs::File::create(&large)
            .unwrap()
            .set_len(SOURCE_BYTES as u64 + 1)
            .unwrap();
        assert!(Source::open(&large, &cancel).is_err());
        let svg = directory.path().join("shape.svg");
        let svg_bytes=br#"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160"><rect width="240" height="160" fill="green"/><circle cx="120" cy="80" r="40" fill="blue"/></svg>"#;
        fs::write(&svg, svg_bytes).unwrap();
        let source = Source::open(&svg, &cancel).unwrap();
        let vector = source.render(1, Some(100), &cancel).unwrap();
        assert!(vector.rgb.as_chunks::<3>().0.contains(&[0, 0, 255]));
        assert_eq!(fs::read(&svg).unwrap(), svg_bytes);
        let pdf = directory.path().join("two-pages.pdf");
        let bytes = sample_pdf();
        fs::write(&pdf, &bytes).unwrap();
        let source = Source::open(&pdf, &cancel).unwrap();
        assert_eq!(source.pages, 2);
        let first = source.render(1, Some(100), &cancel).unwrap();
        let second = source.render(2, Some(150), &cancel).unwrap();
        assert!(first.rgb != second.rgb);
        assert_eq!(fs::read(&pdf).unwrap(), bytes);
        let sandbox = Sandbox::new(b"none", "png").unwrap();
        let status = sandbox
            .run(
                Path::new("/usr/bin/cat"),
                &["/proc/self/status".into()],
                &cancel,
            )
            .unwrap();
        assert!(
            String::from_utf8(status)
                .unwrap()
                .contains("NoNewPrivs:\t1")
        );
        assert!(
            sandbox
                .run(Path::new("/usr/bin/cat"), &["/etc/passwd".into()], &cancel)
                .is_err()
        );
        fs::write(&svg, svg_bytes).unwrap();
        assert!(source.render(1, None, &cancel).is_ok());
        let old = Source::open(&svg, &cancel).unwrap();
        let replacement = directory.path().join("replacement");
        fs::write(&replacement, svg_bytes).unwrap();
        fs::rename(replacement, &svg).unwrap();
        assert!(matches!(old.render(1, None, &cancel), Err(Error::Stale)));
        let cancelled = Cancellation::default();
        let sender = cancelled.clone();
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(80));
            sender.cancel()
        });
        assert!(matches!(
            sandbox.run(Path::new("/usr/bin/sleep"), &["5".into()], &cancelled),
            Err(Error::Cancelled)
        ));
        thread.join().unwrap();
    }
}

#[cfg(test)]
mod rich_image_tests {
    use super::*;
    #[test]
    fn converted_output_read_respects_the_remaining_batch_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("asset.png");
        fs::write(&path, b"12345678").unwrap();
        assert!(matches!(read_output_bounded(&path, 7), Err(Error::Limit)));
        assert_eq!(read_output_bounded(&path, 8).unwrap(), b"12345678");
    }
    #[test]
    #[ignore = "Native bounded image sandbox; isolated authorized Linux session"]
    fn rich_decoder_respects_remaining_pixels_before_thumbnail_decode() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("pixel.png");
        let bytes = include_bytes!("../tests/fixtures/pixel-1.png");
        fs::write(&png, bytes).unwrap();
        let cancel = Cancellation::default();
        assert!(matches!(
            prepare_rich_image_with_budget(bytes, "png", &cancel, true, bytes.len() - 1, 1),
            Err(Error::Limit)
        ));
        assert!(
            prepare_rich_image_with_budget(bytes, "png", &cancel, true, bytes.len(), 1).is_ok()
        );
        let gif = dir.path().join("two.gif");
        assert!(std::process::Command::new(image_backend().unwrap())
            .arg(&png)
            .arg(&png)
            .arg(&gif)
            .status()
            .unwrap()
            .success());
        let bytes = fs::read(&gif).unwrap();
        assert!(matches!(
            prepare_rich_image_with_budget(&bytes, "gif", &cancel, true, bytes.len(), 1),
            Err(Error::Limit)
        ));
        assert!(
            prepare_rich_image_with_budget(&bytes, "gif", &cancel, true, bytes.len(), 2).is_ok()
        );
    }
    #[test]
    #[ignore = "Native bounded image sandbox; isolated authorized Linux session"]
    fn rich_image_formats_bytes_conversion_canvas_and_frame_limits() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("pixel.png");
        let bytes = include_bytes!("../tests/fixtures/pixel-1.png");
        fs::write(&png, bytes).unwrap();
        let cancel = Cancellation::default();
        for extension in ["png", "jpg", "gif", "webp", "tiff"] {
            let path = dir.path().join(format!("pixel.{extension}"));
            if extension != "png" {
                assert!(
                    std::process::Command::new(image_backend().unwrap())
                        .arg(&png)
                        .arg(&path)
                        .status()
                        .unwrap()
                        .success()
                );
            }
            let original = fs::read(&path).unwrap();
            let image = prepare_rich_image(&original, extension, &cancel, true).unwrap();
            assert_eq!((image.width, image.height, image.frames), (1, 1, 1));
            assert!(image.thumbnail.is_some());
            if extension == "tiff" {
                assert!(image.converted);
                assert_eq!(image.extension, "png");
                assert!(image.bytes.starts_with(b"\x89PNG"));
            } else {
                assert!(!image.converted);
                assert_eq!(image.bytes, original);
            }
            assert_eq!(fs::read(&path).unwrap(), original);
        }
        let multi = dir.path().join("multi.tiff");
        assert!(
            std::process::Command::new(image_backend().unwrap())
                .arg(&png)
                .arg(&png)
                .arg(&multi)
                .status()
                .unwrap()
                .success()
        );
        assert!(prepare_rich_image(&fs::read(multi).unwrap(), "tiff", &cancel, false).is_err());
        let mut gif = fs::read(dir.path().join("pixel.gif")).unwrap();
        gif[6..8].copy_from_slice(&60000u16.to_le_bytes());
        gif[8..10].copy_from_slice(&60000u16.to_le_bytes());
        assert!(prepare_rich_image(&gif, "gif", &cancel, false).is_err());
        assert!(prepare_rich_image(bytes, "jpg", &cancel, false).is_err());
        assert!(prepare_rich_image(b"not an image", "png", &cancel, false).is_err());
        let cancelled = Cancellation::default();
        cancelled.cancel();
        assert!(prepare_rich_image(bytes, "png", &cancelled, false).is_err());
    }
}
