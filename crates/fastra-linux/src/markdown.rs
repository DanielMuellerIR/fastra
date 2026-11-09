use super::*;
pub(super) mod autolinks;
pub(super) mod math;
pub(super) mod parser_view;
pub(super) mod syntax;
pub(super) mod visible_blank_lines;
pub(super) mod code_copy;
pub(super) mod positions;
pub(super) mod external_links;
mod html_whitelist;
pub(crate) mod references;
#[cfg(debug_assertions)] mod html_gui_test;
#[cfg(test)] mod html_whitelist_tests;
use pulldown_cmark::{html, Event, Options, Tag, TagEnd};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::Read,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};
use webkit6::prelude::*;

const BASE: &str = "fastra-preview://document/page";
const MAX_IMAGE: usize = 32 * 1024 * 1024;
const MAX_IMAGES: usize = 64 * 1024 * 1024;
#[derive(Clone)]
struct Image {
    bytes: glib::Bytes,
    mime: &'static str,
}
#[derive(Debug)]
pub enum RenderError {
    Limit,
    Cancelled,
    RuntimePath(String),
}

pub struct Rendered {
    pub html: String,
    images: HashMap<String, Image>,
    pub warnings: usize,
    token: String,
    code: code_copy::Registry,
}
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
pub(super) fn decode_path(value: &str) -> Result<PathBuf, String> {
    // Das echte Fragment wird vor dem Prozentdecodieren entfernt; %23 gehört zum Dateinamen.
    let value = value.split('#').next().unwrap_or("");
    let value = if let Some(file) = value.strip_prefix("file://") {
        if file.starts_with('/') {
            file
        } else if let Some(local) = file
            .strip_prefix("localhost")
            .filter(|path| path.starts_with('/'))
        {
            local
        } else {
            return Err("remote image".into());
        }
    } else {
        value
    };
    if value.contains("://") || value.starts_with("//") {
        return Err("remote image".into());
    }
    let input = value.as_bytes();
    let mut bytes = Vec::new();
    let mut index = 0;
    while index < input.len() {
        if input[index] == b'%' {
            if index + 2 >= input.len() {
                return Err("invalid image path".into());
            }
            let hex = std::str::from_utf8(&input[index + 1..index + 3])
                .map_err(|_| "invalid image path")?;
            bytes.push(u8::from_str_radix(hex, 16).map_err(|_| "invalid image path")?);
            index += 3;
        } else {
            bytes.push(input[index]);
            index += 1;
        }
    }
    if bytes.contains(&0) {
        return Err("invalid image path".into());
    }
    use std::os::unix::ffi::OsStringExt;
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
}
enum ImageError { Ordinary, RuntimePath(String) }
impl From<&str> for ImageError {
    fn from(_value: &str) -> Self { Self::Ordinary }
}
impl From<String> for ImageError {
    fn from(_value: String) -> Self { Self::Ordinary }
}
fn image(
    source: &str,
    document: Option<&Path>,
    cancel: &Cancellation,
    budget: usize,
) -> Result<(String, Image), ImageError> {
    cancel.check().map_err(|_| "cancelled")?;
    let relative = decode_path(source)?;
    let path = if relative.is_absolute() {
        relative
    } else {
        document
            .and_then(Path::parent)
            .ok_or("save document before using relative images")?
            .join(relative)
    };
    fastra_io::check_runtime_path(&path).map_err(|e| ImageError::RuntimePath(e.to_string()))?;
    let path = path.canonicalize().map_err(|_| "image not found")?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|_| "image not readable")?;
    fastra_io::check_runtime_file(&file).map_err(|e| ImageError::RuntimePath(e.to_string()))?;
    let maximum = MAX_IMAGE.min(budget);
    let meta = file.metadata().map_err(|_| "image not readable")?;
    if !meta.is_file() || meta.len() > maximum as u64 {
        return Err("image limit".into());
    }
    let mut bytes = Vec::new();
    file.take((maximum + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "image read failed")?;
    if bytes.len() > maximum {
        return Err("image limit".into());
    }
    cancel.check().map_err(|_| "cancelled")?;
    let after = std::fs::metadata(&path).map_err(|_| "image changed")?;
    if (
        meta.dev(),
        meta.ino(),
        meta.len(),
        meta.mtime(),
        meta.mtime_nsec(),
    ) != (
        after.dev(),
        after.ino(),
        after.len(),
        after.mtime(),
        after.mtime_nsec(),
    ) {
        return Err("image changed".into());
    }
    let ext = path
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let mime = match ext.as_str() {
        "png" if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => "image/png",
        "jpg" | "jpeg" if bytes.starts_with(b"\xff\xd8") => "image/jpeg",
        "gif" if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") => "image/gif",
        "webp" if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") => "image/webp",
        _ => return Err("unsupported raster image".into()),
    };
    let mut hash = Sha256::new();
    hash.update(path.as_os_str().as_bytes());
    hash.update(meta.mtime().to_le_bytes());
    hash.update(meta.mtime_nsec().to_le_bytes());
    hash.update(meta.len().to_le_bytes());
    hash.update(&bytes);
    let token = format!("{:x}", hash.finalize());
    Ok((
        token,
        Image {
            bytes: glib::Bytes::from_owned(bytes),
            mime,
        },
    ))
}
pub(super) fn parser_options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_MATH
}
pub fn render(
    source: &str,
    path: Option<&Path>,
    dark: bool,
    de: bool,
    cancel: &Cancellation,
) -> Result<Rendered, RenderError> {
    if source.len() > 4 * 1024 * 1024 {
        return Err(RenderError::Limit);
    }
    let headings = super::markdown_navigation::headings(source, cancel).map_err(|_| {
        if cancel.check().is_err() {
            RenderError::Cancelled
        } else {
            RenderError::Limit
        }
    })?;
    let headings: HashMap<_, _> = headings.iter().map(|h| (h.byte, h)).collect();
    let parsed = syntax::Parsed::new(source, true, cancel).map_err(|_| if cancel.check().is_err() { RenderError::Cancelled } else { RenderError::Limit })?;
    let mut parser = parsed.events(true, cancel).map_err(|_| if cancel.check().is_err() { RenderError::Cancelled } else { RenderError::Limit })?.into_iter();
    let mut events = Vec::new();
    let mut positions = positions::Markers::new(source);
    let mut images = HashMap::new();
    let mut total = 0;
    let mut image_count = 0;
    let mut warnings = 0;
    let mut links = Vec::new();
    let mut raw_html = html_whitelist::Sanitizer::default();
    let mut code = code_copy::Registry::default();
    let mapped_text = !parsed.extraction.tokens().is_empty();
    while let Some((event, range, generated)) = parser.next() {
        cancel.check().map_err(|_| RenderError::Cancelled)?;
        positions.record(&event, range.start);
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                let mut text = String::new();
                events.push(Event::Start(Tag::CodeBlock(kind)));
                for (event, _, _) in parser.by_ref() {
                    match event {
                        Event::End(TagEnd::CodeBlock) => break,
                        Event::Text(part) => {text.push_str(&part); events.push(Event::Text(part));}
                        _ => return Err(RenderError::Limit),
                    }
                }
                code.insert(text)?;
                events.push(Event::End(TagEnd::CodeBlock));
            }
            Event::Start(Tag::Heading { level, .. }) => {
                let offset = range.start;
                let heading = headings.get(&offset).ok_or(RenderError::Limit)?;
                events.push(Event::Html(
                    format!(
                        "<{level} id=\"{}\" data-fastra-offset=\"{}\">",
                        escape(&heading.anchor),
                        heading.offset
                    )
                    .into(),
                ));
            }
            Event::InlineHtml(raw) if generated == syntax::Generated::Mark => events.push(Event::InlineHtml(raw)),
            Event::Html(raw) if generated == syntax::Generated::Blank => events.push(Event::Html(raw)),
            Event::Text(raw) if generated == syntax::Generated::MathSource => {
                let (line,column) = parsed.extraction.source_position(range.start).map_err(|_| RenderError::Limit)?;
                let notice = if de { "Formel mit eingebettetem Code bleibt als Quelltext erhalten" } else { "Formula with embedded code is preserved as source text" };
                events.push(Event::Html(format!("<span class=\"math-source\" data-srcline=\"{line}\" data-srccol=\"{column}\">{}</span><span class=\"math-source-notice\" role=\"note\">{notice}</span>", escape(&raw)).into()));
            }
            Event::Text(text) if mapped_text => {
                let (line,column)=parsed.extraction.source_position(range.start).map_err(|_| RenderError::Limit)?;
                events.push(Event::InlineHtml(format!("<span data-srcline=\"{line}\" data-srccol=\"{column}\">{}</span>",escape(&text)).into()));
            }
            Event::Code(text) if mapped_text => {
                let (line,column)=parsed.extraction.source_position(range.start).map_err(|_| RenderError::Limit)?;
                events.push(Event::InlineHtml(format!("<code data-srcline=\"{line}\" data-srccol=\"{column}\">{}</code>",escape(&text)).into()));
            }
            Event::Html(raw) | Event::InlineHtml(raw) => {
                let sanitized = raw_html.sanitize(&raw, cancel, |src| {
                    image_count += 1;
                    let loaded = if image_count <= 128 { image(src, path, cancel, MAX_IMAGES.saturating_sub(total)) } else { Err("image count limit".into()) };
                    cancel.check().map_err(|_| RenderError::Cancelled)?;
                    if let Err(ImageError::RuntimePath(error)) = &loaded { return Err(RenderError::RuntimePath(error.clone())); }
                    if let Ok((token, image)) = loaded {
                        total += image.bytes.len();images.insert(token.clone(), image);
                        Ok(format!("fastra-preview://image/{token}"))
                    } else { warnings += 1;Ok(String::new()) }
                })?;
                if let Some(sanitized) = sanitized {
                    events.push(Event::Html(raw_html.store(sanitized).into()));
                } else { warnings += 1; }
            }
            Event::InlineMath(ref tex) | Event::DisplayMath(ref tex) => {
                let class = if matches!(event, Event::DisplayMath(_)) {
                    "math-block"
                } else {
                    "math-inline"
                };
                let (line, column) = parsed.extraction.source_position(range.start).map_err(|_| RenderError::Limit)?;
                events.push(Event::Html(
                    format!(
                        "<{tag} class=\"{class}\" data-srcline=\"{line}\" data-srccol=\"{column}\" data-tex=\"{}\">{}</{tag}>",
                        escape(tex),
                        escape(tex),
                        tag = if generated == syntax::Generated::MathBlock { "div" } else { "span" }
                    )
                    .into(),
                ));
            }
            Event::Start(Tag::Image {
                dest_url, title, ..
            }) => {
                let mut alt = String::new();
                for (event, _, _) in parser.by_ref() {
                    match event {
                        Event::End(TagEnd::Image) => break,
                        Event::Text(text) | Event::Code(text) => alt.push_str(&text),
                        _ => {}
                    }
                }
                image_count += 1;
                let loaded = if image_count <= 128 {
                    image(&dest_url, path, cancel, MAX_IMAGES.saturating_sub(total))
                } else {
                    Err("image count limit".into())
                };
                match loaded {
                    Err(ImageError::RuntimePath(error)) => return Err(RenderError::RuntimePath(error)),
                    Ok((token, image)) if total + image.bytes.len() <= MAX_IMAGES => {
                        total += image.bytes.len();
                        let uri = format!("fastra-preview://image/{token}");
                        images.insert(token, image);
                        let location = if mapped_text {
                            let (line,column)=parsed.extraction.source_position(range.start).map_err(|_| RenderError::Limit)?;
                            format!(" data-srcline=\"{line}\" data-srccol=\"{column}\"")
                        } else { String::new() };
                        events.push(Event::Html(
                            format!(
                                "<img{location} src=\"{uri}\" alt=\"{}\" title=\"{}\">",
                                escape(&alt),
                                escape(&title)
                            )
                            .into(),
                        ));
                    }
                    _ => {
                        warnings += 1;
                        events.push(Event::Html(
                            format!(
                                "<span class=\"image-error\">{}: {}</span>",
                                if de {
                                    "Bild nicht verfügbar"
                                } else {
                                    "Image unavailable"
                                },
                                escape(&alt)
                            )
                            .into(),
                        ));
                    }
                }
            }
            Event::Start(Tag::Link { dest_url, .. }) => {
                let anchor = dest_url.starts_with('#') || external_links::allowed_uri(&dest_url);
                links.push(anchor);
                events.push(Event::Html(
                    if anchor {
                        format!("<a href=\"{}\">", escape(&dest_url))
                    } else {
                        format!(
                            "<span class=\"blocked-link\" title=\"{}\">",
                            escape(&dest_url)
                        )
                    }
                    .into(),
                ));
            }
            Event::End(TagEnd::Link) => events.push(Event::Html(
                if links.pop().unwrap_or(false) {
                    "</a>"
                } else {
                    "</span>"
                }
                .into(),
            )),
            event => events.push(event),
        }
    }
    let mut fragment = String::new();
    html::push_html(&mut fragment, events.into_iter());
    let fragment = code.annotate(&fragment).ok_or(RenderError::Limit)?;
    let fragment = positions.annotate(&fragment).ok_or(RenderError::Limit)?;
    let fragment = raw_html.finish(fragment).ok_or(RenderError::Limit)?;
    if fragment.len() > 16 * 1024 * 1024 {
        return Err(RenderError::Limit);
    }
    let nonce = glib::uuid_string_random().replace('-', "");
    let colors = if dark {
        "--fg:#f2f2f2;--bg:#171717;--control:#333;--secondary:#aaa;--border:#484848;--link:#8bb7f2;--mark:#665200"
    } else {
        "--fg:#363636;--bg:#fff;--control:#ececec;--secondary:#737373;--border:#d7d7d7;--link:#3f69a8;--mark:#ffee9a"
    };
    let code_style = include_str!("../../../linux/resources/markdown-code-copy.css");
    let code_script = include_str!("../../../linux/resources/markdown-code-copy.js");
    let style = format!("{}{code_style}{}",visible_blank_lines::CSS,crate::fonts::web_style("fastra-preview"));
    let script = format!("{}{code_script}",include_str!("../../../linux/resources/markdown.js"));
    let page=format!("<!doctype html><html lang=\"{}\" data-dark=\"{dark}\" data-fastra-render=\"{nonce}\"><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; base-uri 'none'; form-action 'none'; img-src fastra-preview:; font-src fastra-preview:; style-src 'unsafe-inline' fastra-preview:; script-src 'nonce-{nonce}' fastra-preview:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'\"><link rel=\"stylesheet\" href=\"fastra-preview://resource/highlight.css\"><style>:root{{{colors}}}mark{{background:var(--mark);color:inherit}}{}{}</style><script src=\"fastra-preview://resource/katex.js\"></script><script src=\"fastra-preview://resource/highlight.js\"></script><script src=\"fastra-preview://resource/mermaid.js\"></script></head><body>{fragment}<script nonce=\"{nonce}\">{}</script></body></html>",if de{"de"}else{"en"},include_str!("../../../linux/resources/markdown.css"),style,script);
    Ok(Rendered {
        html: page,
        images,
        warnings,
        token: nonce,
        code,
    })
}
fn resource(name: &str) -> Option<(&'static [u8], &'static str)> {
    const KATEX: &[u8] =
        include_bytes!("../../../app/Sources/Fastra/Resources/MarkdownVendor/katex-0.17.0.min.js");
    const MERMAID: &[u8] = include_bytes!(
        "../../../app/Sources/Fastra/Resources/MarkdownVendor/mermaid-11.16.0.min.js"
    );
    const HIGHLIGHT: &[u8] = include_bytes!(
        "../../../app/Sources/Fastra/Resources/MarkdownVendor/highlight-11.11.1.min.js"
    );
    const STYLE: &[u8] = include_bytes!(
        "../../../app/Sources/Fastra/Resources/MarkdownVendor/highlight-11.11.1.min.css"
    );
    match name {
        "katex.js" => Some((KATEX, "text/javascript")),
        "mermaid.js" => Some((MERMAID, "text/javascript")),
        "highlight.js" => Some((HIGHLIGHT, "text/javascript")),
        "highlight.css" => Some((STYLE, "text/css")),
        _ => None,
    }
}
pub struct MarkdownView {
    pub widget: gtk::Box,
    pub view: webkit6::WebView,
    pub status: gtk::Label,
    images: Rc<RefCell<HashMap<String, Image>>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    pub visible: Cell<bool>,
    rendered: RefCell<Option<(u64, String)>>,
    pending_jump: Cell<Option<(u64, i32)>>,
    positions: positions::Binding,
    code_copy: code_copy::State,
}
impl MarkdownView {
    pub fn new() -> Rc<Self> {
        let context = webkit6::WebContext::new();
        let images: Rc<RefCell<HashMap<String, Image>>> = Rc::new(RefCell::new(HashMap::new()));
        let map = images.clone();
        context.register_uri_scheme("fastra-preview", move |request| {
            if crate::fonts::serve(request, "fastra-preview") { return; }
            let uri = request.uri().unwrap_or_default();
            let result = if let Some(name) = uri.strip_prefix("fastra-preview://resource/") {
                resource(name).map(|(bytes, mime)| (glib::Bytes::from_static(bytes), mime))
            } else if let Some(token) = uri.strip_prefix("fastra-preview://image/") {
                map.borrow()
                    .get(token)
                    .map(|image| (image.bytes.clone(), image.mime))
            } else {
                None
            };
            if let Some((bytes, mime)) = result {
                let stream = gio::MemoryInputStream::from_bytes(&bytes);
                request.finish(&stream, bytes.len() as i64, Some(mime));
            } else {
                request.finish_error(&mut glib::Error::new(
                    gio::IOErrorEnum::PermissionDenied,
                    "Unlisted preview resource",
                ));
            }
        });
        if let Some(security) = context.security_manager() {
            security.register_uri_scheme_as_local("fastra-preview");
            security.register_uri_scheme_as_secure("fastra-preview");
            security.register_uri_scheme_as_display_isolated("fastra-preview");
        }
        let session = webkit6::NetworkSession::new_ephemeral();
        let manager = webkit6::UserContentManager::new();
        manager.register_script_message_handler("markdownPosition", None);
        let view = webkit6::WebView::builder()
            .user_content_manager(&manager)
            .web_context(&context)
            .network_session(&session)
            .hexpand(true)
            .vexpand(true)
            .build();
        let settings = webkit6::Settings::new();
        settings.set_enable_html5_database(false);
        settings.set_enable_html5_local_storage(false);
        settings.set_javascript_can_open_windows_automatically(false);
        settings.set_enable_write_console_messages_to_stdout(false);
        settings.set_enable_dns_prefetching(false);
        view.set_settings(&settings);
        crate::editor_options::zoom::install_web(&view);
        crate::editor_options::appearance::install_web(&view);
        crate::editor_options::reading_font::install_web(&view);
        view.connect_permission_request(|_, request| {
            request.deny();
            true
        });
        view.connect_context_menu(|_, _, _| true);
        let status = gtk::Label::new(None);
        status.set_wrap(true);
        status.set_xalign(0.);
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 6);
        widget.append(&view);
        widget.append(&status);
        let result = Rc::new(Self {
            widget,
            view,
            status,
            images,
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            visible: Cell::new(false),
            rendered: RefCell::new(None),
            pending_jump: Cell::new(None),
            positions: positions::Binding::default(),
            code_copy: code_copy::State::default(),
        });
        external_links::install(&result);
        code_copy::connect(&manager, &result);
        let weak = Rc::downgrade(&result);
        manager.connect_script_message_received(Some("markdownPosition"), move |_, value| {
            if let Some(preview) = weak.upgrade() {
                if let Some(raw) = value.to_json(0).filter(|raw| raw.len() <= 512) {
                    if let Ok(value) = serde_json::from_str(&raw) { positions::message(&preview, value); }
                }
            }
        });
        let weak = Rc::downgrade(&result);
        result.view.connect_load_changed(move |_, event| {
            if event == webkit6::LoadEvent::Finished {
                if let Some(preview) = weak.upgrade() {
                    positions::ready(&preview);
                    preview.apply_jump();
                    positions::apply_reveal(&preview);
                }
            }
        });
        result
    }
    pub(crate) fn print_token(&self, revision: u64) -> Option<String> {
        self.rendered
            .borrow()
            .as_ref()
            .filter(|(rendered_revision, _)| *rendered_revision == revision && self.visible.get())
            .map(|(_, token)| token.clone())
    }
    pub(super) fn jump(self: &Rc<Self>, revision: u64, offset: i32) {
        self.pending_jump.set(Some((revision, offset)));
        self.apply_jump();
    }
    fn apply_jump(self: &Rc<Self>) {
        let Some((revision, offset)) = self.pending_jump.get() else {
            return;
        };
        let Some(token) = self.print_token(revision) else {
            return;
        };
        let script = format!("const token={}; for(let n=0;n<400;n++){{if(document.documentElement.dataset.fastraRender!==token)return false;if(window.fastraPreviewReady===true)break;await new Promise(resolve=>setTimeout(resolve,25));}}if(document.documentElement.dataset.fastraRender!==token||window.fastraPreviewReady!==true)return false;const el=document.querySelector('[data-fastra-offset=\"{offset}\"]');if(!el)return false;el.scrollIntoView({{block:'start'}});return true;", serde_json::json!(token));
        let weak = Rc::downgrade(self);
        self.view.call_async_javascript_function(
            &script,
            None,
            None,
            None,
            None::<&gio::Cancellable>,
            move |result| {
                if let Some(preview) = weak.upgrade() {
                    if result.is_ok_and(|value| value.to_boolean())
                        && preview.pending_jump.get() == Some((revision, offset))
                        && preview.rendered.borrow().as_ref() == Some(&(revision, token))
                    {
                        preview.pending_jump.set(None);
                    }
                }
            },
        );
    }
    pub fn stop(&self) {
        self.code_copy.invalidate();
        self.positions.invalidate();
        self.rendered.borrow_mut().take();
        self.pending_jump.set(None);
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
    }
    pub fn schedule(self: &Rc<Self>, doc: &Rc<Document>, lang: Language) {
        self.stop();
        self.status.set_tooltip_text(Some(lang.text("HTML verwendet eine enge Positivliste. Bilder: PNG, JPEG, GIF und WebP; keine Netzabrufe.","HTML uses a strict allowlist. Images: PNG, JPEG, GIF and WebP; no network loads.")));
        if !doc.has_source_text() || doc.is_rich_active() || !self.visible.get() {
            return;
        }
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        let document = Rc::downgrade(doc);
        glib::timeout_add_local_once(Duration::from_millis(180), move || {
            let (Some(preview), Some(doc)) = (weak.upgrade(), document.upgrade()) else {
                return;
            };
            if generation != preview.generation.get() {
                return;
            }
            let source = buffer_text(&doc.buffer);
            let revision = doc.revision.get();
            let path = doc.disk_path();
            let dark = crate::editor_options::appearance::dark(&gtk::prelude::WidgetExt::settings(&preview.view));
            let cancel = Cancellation::default();
            *preview.cancel.borrow_mut() = cancel.clone();
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(render(&source, path.as_deref(), dark, lang.0, &cancel));
            });
            let weak = Rc::downgrade(&preview);
            let document = Rc::downgrade(&doc);
            glib::timeout_add_local(Duration::from_millis(20), move || {
                let (Some(preview), Some(doc)) = (weak.upgrade(), document.upgrade()) else {
                    return glib::ControlFlow::Break;
                };
                if preview.generation.get() != generation || doc.revision.get() != revision {
                    return glib::ControlFlow::Break;
                }
                match rx.try_recv() {
                    Ok(Ok(rendered)) => {
                        let warnings = rendered.warnings;
                        preview.code_copy.install(rendered.token.clone(),rendered.code,lang);
                        *preview.images.borrow_mut() = rendered.images;
                        *preview.rendered.borrow_mut() = Some((revision, rendered.token));
                        preview.view.load_html(&rendered.html, Some(BASE));
                        preview.status.set_text(&format!(
                            "{} · {} {}",
                            lang.text(
                                "Lokale Markdown-Vorschau (Teilumfang)",
                                "Local Markdown preview (partial)"
                            ),
                            warnings,
                            if warnings == 1 {
                                lang.text("Hinweis zu HTML/Bildern", "HTML/image notice")
                            } else {
                                lang.text("Hinweise zu HTML/Bildern", "HTML/image notices")
                            }
                        ));
                        glib::ControlFlow::Break
                    }
                    Ok(Err(error)) => {
                        if let RenderError::RuntimePath(message) = &error {
                            preview.status.set_text(message);
                            return glib::ControlFlow::Break;
                        }
                        preview.status.set_text(match error {
                            RenderError::Limit => lang.text(
                                "Die Markdown-Vorschau überschreitet ihre Größen- oder Komplexitätsgrenze.",
                                "The Markdown preview exceeds its size or complexity limit.",
                            ),
                            RenderError::RuntimePath(_) => unreachable!(),
                            RenderError::Cancelled => lang.text(
                                "Markdown-Vorschau abgebrochen.",
                                "Markdown preview cancelled.",
                            ),
                        });
                        glib::ControlFlow::Break
                    }
                    Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                    Err(_) => glib::ControlFlow::Break,
                }
            });
        });
    }
}

#[cfg(debug_assertions)]
impl MarkdownView {
    pub fn inspect(&self, code: &str, done: impl FnOnce(serde_json::Value) + 'static) {
        self.view.call_async_javascript_function(
            code,
            None,
            None,
            None,
            None::<&gio::Cancellable>,
            move |result| {
                let value = result
                    .ok()
                    .and_then(|value| serde_json::from_str(&value.to_str()).ok())
                    .unwrap_or(serde_json::Value::Null);
                done(value);
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn visible_blank_static_rendering_is_trusted_only_for_generated_events() {
        let source="雪\r\n  \r\n- One\r\n  \r\n- Two\r\n  \r\nEnd";
        let rendered=render(source,None,false,false,&Cancellation::default()).unwrap();
        assert_eq!(rendered.html.matches("class=\"fastra-visible-blank-line\"").count(),3);
        assert!(rendered.html.contains("data-srcline=\"2\""));
        assert_eq!(rendered.html.matches("<ul").count(),1);
        assert_eq!(rendered.html.matches("<li data-srcline=").count(),2);
        let forged=render("<div class=\"fastra-visible-blank-line\"><br></div>",None,false,false,&Cancellation::default()).unwrap();
        assert!(forged.warnings>0);
        assert!(!forged.html.contains("<div class=\"fastra-visible-blank-line\">"));
    }

    #[test]
    fn gfm_corpus_and_explicit_dialect_gaps() {
        let cases = [
            ("|a|b|\n|-|-|\n|1|2|\n", "<table data-srcline=\"1\">"),
            ("- [x] task\n", "checked=\"\""),
            ("~~gone~~", "<del>gone</del>"),
            ("one\ntwo", "one\ntwo"),
            ("==marked==", "<mark>marked</mark>"),
            ("text\n  \nnext", "<p data-srcline=\"3\">next</p>"),
            ("```js\nconst a=1;\n```", "language-js"),
            ("note[^1]\n\n[^1]: footnote", "footnote-definition"),
            ("$x^2$", "data-tex=\"x^2\""),
        ];
        for (source, expected) in cases {
            let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
            assert!(
                rendered.html.contains(expected),
                "{source}: missing {expected}"
            );
        }
        let rendered = render(
            "[outside](https://example.invalid) [blocked](file:///tmp/a) ![no](https://example.invalid/a.png)",
            None,
            false,
            false,
            &Cancellation::default(),
        )
        .unwrap();
        assert!(rendered.html.contains("href=\"https://example.invalid\""));
        assert!(!rendered.html.contains("src=\"https:"));
        assert!(rendered.html.contains("connect-src 'none'"));
        assert!(rendered.html.contains("blocked-link"));
    }
    #[test]
    fn mark_preview_preserves_original_heading_offsets_and_html_boundary() {
        let source =
            "==Marked==\n\n# ==Heading==\n\n<mark>literal</mark>\n\n`==code==`\n\n==**Bold**==";
        let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
        assert!(rendered.html.contains("<mark>Marked</mark>"));
        assert!(rendered.html.contains("data-fastra-offset=\"12\""));
        assert!(rendered.html.contains("<mark>Heading</mark>"));
        assert!(rendered.html.contains("<mark>literal</mark>"));
        assert!(rendered.html.contains("<code>==code==</code>"));
        assert!(rendered.html.contains("<mark><strong>Bold</strong></mark>"));
    }
    #[test]
    fn percent_hash_and_image_content_identity() {
        assert_eq!(
            decode_path("file://localhost/tmp/pixel%23a.png#anchor").unwrap(),
            PathBuf::from("/tmp/pixel#a.png")
        );
        assert!(decode_path("file://remote.invalid/tmp/pixel.png").is_err());
        let root = std::env::temp_dir().join(format!("fastra-md-image-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("pixel#a.png");
        let doc = root.join("document.md");
        std::fs::write(&file, include_bytes!("../tests/fixtures/pixel-1.png")).unwrap();
        let first = render(
            "![pixel](pixel%23a.png#fragment)",
            Some(&doc),
            false,
            false,
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(first.images.len(), 1);
        let one = first.images.keys().next().unwrap();
        std::fs::write(&file, include_bytes!("../tests/fixtures/pixel-2.png")).unwrap();
        let second = render(
            "![pixel](pixel%23a.png#fragment)",
            Some(&doc),
            false,
            false,
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(second.images.len(), 1);
        assert_ne!(one, second.images.keys().next().unwrap());
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
}

#[cfg(test)]
mod math_static_tests;

#[cfg(debug_assertions)]
mod math_gui_test;

#[cfg(test)] mod raw_html_port_gate {
    use super::*;
    #[test] fn raw_html_readme_center_and_details_are_real_elements() {
        let source="<p align=\"center\"><b>café 🙂</b></p>\n\n<details>\n<summary>More</summary>\n\nNormal **Markdown**.\n\n</details>\n";
        let rendered=render(source,None,false,false,&Cancellation::default()).unwrap();
        assert!(rendered.html.contains("<p align=\"center\"><b>café 🙂</b></p>"),"allowed raw README HTML must render");
        assert!(rendered.html.contains("<details>"));
        assert!(rendered.html.contains("<summary>More</summary>"));
        assert!(rendered.html.contains("<strong>Markdown</strong>"));
    }
}

#[cfg(debug_assertions)]
pub(crate) mod external_links_gui_test;

#[cfg(test)] mod autolink_tests;
#[cfg(test)] mod autolink_official_tests;
#[cfg(test)] mod autolink_footnote_tests;
