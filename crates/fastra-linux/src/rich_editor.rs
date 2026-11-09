use super::*;
use pulldown_cmark::{html, Event, Options, Parser, Tag, TagEnd};
use serde_json::{json, Value};
use webkit6::prelude::*;
use super::markdown::visible_blank_lines;

pub(super) mod mark;
mod math_page;
mod code_blocks;
#[cfg(debug_assertions)]
mod code_gui_test;
#[cfg(debug_assertions)]
mod math_gui_test;
#[cfg(debug_assertions)]
mod autolink_gui_test;
mod clipboard;
mod transfer;
mod images;
mod image_watch;
pub(crate) mod source_replacement;
#[cfg(debug_assertions)]
mod image_watch_gui_test;
pub(super) mod asset_flow;
pub(super) mod asset_refs;
mod asset_ui;
mod asset_copy;
mod asset_drop;
#[cfg(debug_assertions)]
mod asset_gui;
#[cfg(debug_assertions)]
mod asset_gui_transfer;
#[cfg(debug_assertions)]
mod asset_gui_drop;
mod viewport;
mod navigation;
pub(crate) mod mode;
mod find;
pub(crate) mod snippet;
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
mod formatting_test;
#[cfg(debug_assertions)]
mod blank_lines_gui_test;
#[cfg(debug_assertions)]
mod blank_lines_clipboard_gui_test;

const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_BLOCKS: usize = 10_000;
const BASE: &str = "fastra-rich://document/page";
const VENDOR: &str = "fastra-rich://resource/";

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
fn safe_link(destination: &str) -> bool {
    !destination.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
        && (destination.starts_with('#')
            || destination.starts_with("https://")
            || destination.starts_with("http://")
            || destination.starts_with("mailto:"))
}

fn safe_inline(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    let value = lower
        .trim()
        .trim_start_matches('<')
        .trim_end_matches('>')
        .trim_start_matches('/')
        .trim_end_matches('/')
        .trim();
    raw.starts_with('<')
        && raw.ends_with('>')
        && matches!(
            value,
            "strong"
                | "b"
                | "em"
                | "i"
                | "mark"
                | "del"
                | "s"
                | "u"
                | "ins"
                | "small"
                | "sub"
                | "sup"
                | "kbd"
                | "samp"
                | "var"
                | "q"
                | "cite"
                | "br"
        )
}
struct Page {
    html: String,
    body: String,
    configuration: Value,
    fragment: String,
}
fn append_blank_gap(
    source: &str,
    mut source_start: usize,
    formulas: &[std::ops::Range<usize>],
    blocks: &mut Vec<Value>,
    body: &mut String,
    clipboard: &mut String,
) -> Result<(), &'static str> {
    for (line, visible) in visible_blank_lines::gaps(source) {
        let before = formulas.partition_point(|range| range.end <= source_start);
        let visible = visible
            && !formulas
                .get(before)
                .is_some_and(|range| range.start <= source_start && source_start < range.end);
        source_start += line.len();
        let id = blocks.len();
        if visible {
            let fragment = format!("<div class=\"{}\"><br></div>", visible_blank_lines::CLASS);
            body.push_str(&format!("<div data-md-block=\"{id}\">{fragment}</div>"));
            clipboard.push_str(&fragment);
        }
        blocks.push(json!({"id":id,"source":line,"hidden":!visible}));
        if blocks.len() > MAX_BLOCKS || body.len() > 8 * MAX_BYTES {
            return Err("size");
        }
    }
    Ok(())
}
// Unveränderte Blöcke behalten ihre Originalbytes; unbekannte Syntax bleibt ein geschütztes Atom.
fn page(source: &str, session: &str, dark: bool, de: bool) -> Result<Page, &'static str> {
    page_images(source,session,dark,de,None)
}
fn page_images(source:&str,session:&str,dark:bool,de:bool,image_sources:Option<&images::Sources>)->Result<Page,&'static str>{
    if source.len() > MAX_BYTES || source.contains('\0') {
        return Err("size");
    }
    if source.contains('$') || crate::markdown::autolinks::may_link(source) { return math_page::page(source,session,dark,de,image_sources); }
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_MATH;
    let mapped = crate::markdown::math::normalized(source, crate::markdown::math::Budget::default(), &Cancellation::default()).map_err(|_| "size")?;
    let formulas = mapped.protected_regions(crate::markdown::math::Budget::default(), &Cancellation::default()).map_err(|_| "size")?;
    let line_starts = visible_blank_lines::line_starts(source);
    let mut blocks = Vec::new();
    let mut opaque = serde_json::Map::new();
    let mut body = String::new();
    let mut clipboard_fragment = String::new();
    let mut events = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    let mut cursor = 0usize;
    let mut protected = false;
    let mut event_count = 0usize;
    let parser_source = mapped.prepared();
    let mut view_start = 0usize;
    let mut parser = Parser::new_ext(parser_source, options).into_offset_iter();
    while let Some((event, range)) = parser.next() {
        event_count += 1;
        if event_count > 50_000 {
            return Err("size");
        }
        let original_range = mapped.original_range(range.clone()).map_err(|_| "parse")?.bytes;
        if depth == 0 {
            view_start = range.start;
            start = original_range.start;
            if start > cursor {
                append_blank_gap(&source[cursor..start], cursor, &formulas, &mut blocks, &mut body, &mut clipboard_fragment)?;
            }
        }
        match &event {
            Event::Start(_) => depth += 1,
            Event::End(_) => depth = depth.checked_sub(1).ok_or("parse")?,
            _ => {}
        }
        protected |= match &event {
            Event::Html(_) => true,
            Event::InlineHtml(raw) => !safe_inline(raw),
            Event::Start(Tag::Link { dest_url, .. }) => !safe_link(dest_url),
            Event::Start(Tag::Image{dest_url,..})=>image_sources.is_none_or(|sources|!sources.0.contains_key(dest_url.as_ref())),
            Event::Start(Tag::FootnoteDefinition(_)) => { true }
            Event::InlineMath(_) | Event::DisplayMath(_) | Event::FootnoteReference(_) => true,
            _ => false,
        };
        events.push((event, range.clone()));
        if depth != 0 {
            continue;
        }
        let end = original_range.end;
        let original = &source[start..end];
        let parser_block = &parser_source[view_start..range.end];
        let before = formulas.partition_point(|r| r.end <= start);
        protected |= formulas.get(before).is_some_and(|r| r.start < end);
        let id = blocks.len();
        let marked = if protected { None } else {
            match mark::rewrite(parser_block, options) { Ok(value) => value, Err(_) => { protected = true; None } }
        };
        let fragment = if protected {
            let key = format!("atom-{session}-{id}");
            opaque.insert(key.clone(), Value::String(original.into()));
            format!("<div data-md-opaque=\"{key}\" contenteditable=\"false\" class=\"protected\"><pre>{}</pre></div>",escape(original))
        } else {
            let mut fragment = String::new();
            let mut links = 0usize;
            let first_line = line_starts.partition_point(|offset| *offset <= start).max(1);
            let rendered_events = if let Some(marked) = marked.as_deref() {
                // Auch nach dem bestehenden Mark-Rewrite gehören Referenzen
                // weiterhin zu den Definitionen des vollständigen Dokuments.
                let definitions = parser.reference_definitions();
                let resolve = |link: pulldown_cmark::BrokenLink<'_>| {
                    definitions.get(&link.reference).map(|definition| (
                        definition.dest.to_string().into(),
                        definition.title.as_ref().map_or("", |title| title.as_ref()).to_owned().into(),
                    ))
                };
                let parser = Parser::new_with_broken_link_callback(marked, options, Some(resolve));
                visible_blank_lines::insert_with_math(marked, parser.into_offset_iter(), first_line, false)
            } else {
                visible_blank_lines::insert_with_math(parser_block,
                    std::mem::take(&mut events).into_iter().map(|(event, range)|
                        (event, range.start - view_start..range.end - view_start)), first_line, false)
            }.map_err(|_| "size")?.into_iter().map(|event| event.0);
            let mut image_tags=Vec::new();
            let safe = rendered_events.map(|event| match event {
                Event::Start(Tag::Image{link_type,dest_url,title,id}) if image_sources.is_some_and(|sources|sources.0.contains_key(dest_url.as_ref()))=>{
                    let source=&image_sources.unwrap().0[dest_url.as_ref()];let uri=format!("{}{}",images::PREFIX,source.token);image_tags.push((uri.clone(),dest_url.to_string()));
                    Event::Start(Tag::Image{link_type,dest_url:uri.into(),title,id})
                }
                Event::Start(Tag::Link { dest_url, .. }) => {
                    links += 1;
                    Event::Html(format!("<a href=\"{}\">", escape(&dest_url)).into())
                }
                Event::End(TagEnd::Link) if links > 0 => {
                    links -= 1;
                    Event::Html("</a>".into())
                }
                other => other,
            });
            html::push_html(&mut fragment, code_blocks::enhance(safe, original, &mut opaque, session, id));
            for (uri,source) in image_tags{fragment=fragment.replace(&format!("src=\"{}\"",escape(&uri)),&format!("src=\"{}\" data-md-src=\"{}\"",escape(&uri),escape(&source)));}
            fragment.replace("<table>", "<table data-md-table=\"gfm\">")
        };
        clipboard_fragment.push_str(&fragment);
        body.push_str(&format!("<div data-md-block=\"{id}\">{fragment}</div>"));
        blocks.push(json!({"id":id,"source":original,"hidden":false}));
        if blocks.len() > MAX_BLOCKS || body.len() > 8 * MAX_BYTES {
            return Err("size");
        }
        cursor = end;
        events.clear();
        protected = false;
    }
    if cursor < source.len() {
        append_blank_gap(&source[cursor..], cursor, &formulas, &mut blocks, &mut body, &mut clipboard_fragment)?;
    }
    let configuration =
        json!({"blocks":blocks,"opaqueSources":opaque,"markdown":source,"session":session});
    let page=page_html(&body,dark,de);
    Ok(Page {
        html: page,
        body,
        configuration,
        fragment: clipboard_fragment,
    })
}

fn page_html(body:&str,dark:bool,de:bool)->String {
    let colors = if dark {
        "--fg:#f2f2f2;--bg:#171717;--control:#333;--secondary:#aaa;--border:#484848;--link:#8bb7f2"
    } else {
        "--fg:#363636;--bg:#fff;--control:#ececec;--secondary:#737373;--border:#d7d7d7;--link:#3f69a8"
    };
    let nonce = glib::uuid_string_random();
    let text_style = format!("{}{}",visible_blank_lines::CSS,crate::fonts::web_style("fastra-rich"));
    format!(
        r#"<!doctype html><html lang="{}" data-fastra-enhanced="true" data-dark="{dark}"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'; img-src fastra-rich:; font-src fastra-rich:; media-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; style-src 'unsafe-inline' fastra-rich:; script-src 'nonce-{nonce}' fastra-rich:"><link rel="stylesheet" href="{VENDOR}highlight.css"><style>:root{{{colors}}}{}{} #fastra-visual{{outline:none;min-height:240px}} .protected{{border:1px solid var(--border);padding:8px;color:var(--secondary)}} mark{{background:{};color:inherit}} table{{border-collapse:collapse}} td,th{{min-width:40px}} </style><script src="{VENDOR}katex.js"></script><script src="{VENDOR}highlight.js"></script><script src="{VENDOR}mermaid.js"></script><script src="{VENDOR}math.js"></script><script src="{VENDOR}turndown.js"></script><script src="{VENDOR}tables.js"></script><script src="{VENDOR}editor.js"></script></head><body><div id="fastra-visual" contenteditable="false">{body}</div></body></html>"#,
        if de { "de" } else { "en" },
        include_str!("../../../linux/resources/markdown.css"), text_style,
        if dark { "#665200" } else { "#FFEE9A" }
    )
}

fn resource(name: &str) -> Option<&'static [u8]> {
    match name {
        "katex.js" => Some(include_bytes!("../../../app/Sources/Fastra/Resources/MarkdownVendor/katex-0.17.0.min.js")),
        "highlight.css" => Some(include_bytes!("../../../app/Sources/Fastra/Resources/MarkdownVendor/highlight-11.11.1.min.css")),
        "highlight.js" => Some(include_bytes!("../../../app/Sources/Fastra/Resources/MarkdownVendor/highlight-11.11.1.min.js")),
        "mermaid.js" => Some(include_bytes!("../../../app/Sources/Fastra/Resources/MarkdownVendor/mermaid-11.16.0.min.js")),
        "math.js" => Some(include_bytes!("../../../linux/resources/rich-math.js")),
        "turndown.js" => Some(include_bytes!(
            "../../../app/Sources/Fastra/Resources/MarkdownVendor/turndown-7.2.0.js"
        )),
        "tables.js" => Some(include_bytes!(
            "../../../app/Sources/Fastra/Resources/MarkdownVendor/visual-tables.js"
        )),
        "editor.js" => Some(include_bytes!(
            "../../../app/Sources/Fastra/Resources/MarkdownVendor/visual-editor.js"
        )),
        _ => None,
    }
}

fn changed_range(old: &str, new: &str) -> (usize, usize) {
    let mut prefix = old
        .bytes()
        .zip(new.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(prefix) || !new.is_char_boundary(prefix) {
        prefix -= 1;
    }
    let mut suffix = old.as_bytes()[prefix..]
        .iter()
        .rev()
        .zip(new.as_bytes()[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (prefix, suffix)
}
pub(super) type CloseStamp = (bool,bool,bool,bool,u64,u64,u64,u64,bool);
type Completion = Box<dyn FnOnce(bool)>;
pub struct RichEditor {
    outline: RefCell<Option<Rc<crate::markdown_navigation::View>>>,
    navigation_source_completion: RefCell<Option<Completion>>,
    source_display: RefCell<Option<Rc<mode::SourceDisplay>>>,
    find: RefCell<Option<Rc<find::Bar>>>,
    pub widget: gtk::Box,
    more: gtk::Box,
    pub view: webkit6::WebView,
    status: gtk::Label,
    document: std::rc::Weak<Document>,
    ui: std::rc::Weak<Ui>,
    session: String,
    source_preview: bool,
    expected: RefCell<String>,
    revision: Cell<u64>,
    input_revision: Cell<u64>,
    ready: Cell<bool>,
    pub active: Cell<bool>,
    busy: Cell<bool>,
    failed: Cell<bool>,
    operation: Cell<u64>,
    clipboard_request: Cell<u64>,
    clipboard_busy: Cell<bool>,
    images:Rc<RefCell<images::Cache>>,
    image_cancel:crate::viewer::Cancellation,
    assets:Rc<RefCell<asset_ui::State>>,
}
impl RichEditor {
    pub fn new(ui: &Rc<Ui>, doc: &Rc<Document>) -> Result<Rc<Self>, String> {
        let source = buffer_text(&doc.buffer);
        let session = glib::uuid_string_random().to_string();
        let dark = crate::editor_options::appearance::dark(&ui.window.settings());
        let image_sources=images::Sources::collect(&source,doc.disk_path().as_deref(),&session)?;
        let image_cache=Rc::new(RefCell::new(images::Cache::default()));
        let image_cancel=crate::viewer::Cancellation::default();
        let mut page = page_images(&source, &session, dark, ui.lang.0,Some(&image_sources)).map_err(|_| {
            ui.lang
                .text(
                    "Rich-Markdown: höchstens 2 MiB und 10.000 Blöcke; kein Nullzeichen.",
                    "Rich Markdown: at most 2 MiB and 10,000 blocks; no NUL character.",
                )
                .to_owned()
        })?;
        page.configuration["clipboardLimit"] = json!(MAX_BYTES);
        page.configuration["sourceReplacements"] = json!(true);
        if let Some(saved) = viewport::get(doc) { page.configuration["viewport"] = saved; }
        let context = webkit6::WebContext::new();
        let cached=image_cache.clone();
        context.register_uri_scheme("fastra-rich",move |request| {
            if crate::fonts::serve(request, "fastra-rich") { return; }
            let uri = request.uri().unwrap_or_default();
            if let Some(bytes) = uri.strip_prefix(VENDOR).and_then(resource) {
                let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from_static(bytes));
                request.finish(&stream, bytes.len() as i64, Some(if uri.ends_with(".css") { "text/css" } else { "text/javascript" }));
            } else if let Some(token)=uri.strip_prefix(images::PREFIX){cached.borrow().serve(request,token);}else {
                request.finish_error(&mut glib::Error::new(
                    gio::IOErrorEnum::PermissionDenied,
                    "Unlisted rich editor resource",
                ));
            }
        });
        if let Some(security) = context.security_manager() {
            security.register_uri_scheme_as_local("fastra-rich");
            security.register_uri_scheme_as_secure("fastra-rich");
            security.register_uri_scheme_as_display_isolated("fastra-rich");
        }
        let manager = webkit6::UserContentManager::new();
        manager.register_script_message_handler("visualMarkdown", None);
        manager.register_script_message_handler("markdownCopy", None);
        let view = webkit6::WebView::builder()
            .web_context(&context)
            .network_session(&webkit6::NetworkSession::new_ephemeral())
            .user_content_manager(&manager)
            .hexpand(true)
            .vexpand(true)
            .build();
        let settings = webkit6::Settings::new();
        settings.set_enable_html5_database(false);
        settings.set_enable_html5_local_storage(false);
        settings.set_javascript_can_open_windows_automatically(false);
        view.set_settings(&settings);
        crate::editor_options::zoom::install_web(&view);
        crate::editor_options::appearance::install_web(&view);
        crate::editor_options::reading_font::install_web(&view);
        view.connect_permission_request(|_, request| {
            request.deny();
            true
        });
        view.connect_context_menu(|_, _, _| true);
        view.connect_decide_policy(|_, decision, kind| {
            if matches!(
                kind,
                webkit6::PolicyDecisionType::NavigationAction
                    | webkit6::PolicyDecisionType::NewWindowAction
            ) {
                let allowed = decision
                    .downcast_ref::<webkit6::NavigationPolicyDecision>()
                    .and_then(|d| d.navigation_action())
                    .and_then(|a| a.request())
                    .and_then(|r| r.uri())
                    .is_some_and(|uri| uri == BASE);
                if !allowed {
                    decision.ignore();
                    return true;
                }
            }
            false
        });
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.add_css_class("rich-editor");
        let toolbar = gtk::FlowBox::builder()
            .min_children_per_line(32)
            .max_children_per_line(32)
            .selection_mode(gtk::SelectionMode::None)
            .row_spacing(4)
            .column_spacing(4)
            .build();
        toolbar.set_halign(gtk::Align::Start);
        toolbar.add_css_class("rich-toolbar");
        let toolbar_scroll = gtk::ScrolledWindow::builder().child(&toolbar).hscrollbar_policy(gtk::PolicyType::Automatic).vscrollbar_policy(gtk::PolicyType::Never).min_content_height(28).max_content_height(38).propagate_natural_height(true).build();
        widget.append(&toolbar_scroll);
        widget.append(&view);
        let status = gtk::Label::new(None);
        status.set_visible(false);
        status.set_wrap(true);
        status.set_xalign(0.);
        status.connect_label_notify(|label| label.set_visible(!label.text().is_empty()));
        widget.append(&status);
        let more_box=gtk::Box::new(gtk::Orientation::Vertical,4);
        let editor = Rc::new(Self {
            outline: RefCell::new(None),
            navigation_source_completion: RefCell::new(None),
            source_display: RefCell::new(None),
            find: RefCell::new(None),
            widget,
            more: more_box.clone(),
            view,
            status,
            document: Rc::downgrade(doc),
            ui: Rc::downgrade(ui),
            session,
            source_preview: doc.markdown_toggle.borrow().as_ref().is_some_and(|preview|preview.is_active()),
            expected: RefCell::new(source),
            revision: Cell::new(doc.revision.get()),
            input_revision: Cell::new(0),
            ready: Cell::new(false),
            active: Cell::new(true),
            busy: Cell::new(false),
            failed: Cell::new(false),
            operation: Cell::new(0),
            clipboard_request: Cell::new(0),
            clipboard_busy: Cell::new(false),
            images:image_cache.clone(),image_cancel:image_cancel.clone(),assets:Rc::new(RefCell::new(asset_ui::State::default())),
        });
        asset_drop::install(&editor);
        navigation::install(&editor, &toolbar);
        let snippets = chrome::icon("fastra-snippets-symbolic", ui.lang.text("Textbausteine…", "Text snippets…"));
        let owner = Rc::downgrade(ui);
        snippets.connect_clicked(move |_| {
            if let Some(ui) = owner.upgrade() { crate::workflow_view::show(&ui, true); }
        });
        toolbar.insert(&snippets, -1);
        *editor.find.borrow_mut() = Some(find::install(&editor, &toolbar));
        for &(command,de,en,symbol) in &super::markdown_inline::COMMANDS[..13] {
            let button = gtk::Button::new();
            let title = ui.lang.text(de, en);
            button.set_icon_name(symbol); button.set_has_frame(false); button.set_size_request(26,22); button.set_focus_on_click(false); button.set_tooltip_text(Some(title)); button.update_property(&[gtk::accessible::Property::Label(title)]);
            let weak = Rc::downgrade(&editor);
            button.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.command(command);
                }
            });
            toolbar.insert(&button, -1);
            if matches!(command,"hardBreak"|"plainParagraph"|"quote") {
                let separator=gtk::Separator::new(gtk::Orientation::Vertical);
                separator.set_margin_top(5);separator.set_margin_bottom(5);toolbar.insert(&separator,-1);
            }
        }
        let more=gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(ui.lang.text("Weitere Rich-Aktionen","More rich actions")).build();
        let more_popover=gtk::Popover::new();more_popover.set_child(Some(&more_box));more.set_popover(Some(&more_popover));
        for (de,en,command) in [("Rückgängig","Undo","undo"),("Wiederholen","Redo","redo")] {
            let button=gtk::Button::with_label(ui.lang.text(de,en));let weak=Rc::downgrade(&editor);let popup=more_popover.clone();
            button.connect_clicked(move |_|{popup.popdown();if let Some(editor)=weak.upgrade(){editor.command(command);}});more_box.append(&button);
        }
        let clipboard_menu=gtk::MenuButton::builder().label(ui.lang.text("Zwischenablage","Clipboard")).build();
        let clipboard_popover=gtk::Popover::new();let clipboard_box=gtk::Box::new(gtk::Orientation::Vertical,6);
        for (de,en,action) in [("Kopieren","Copy","copy"),("Ausschneiden","Cut","cut"),("Einfügen","Paste","paste"),("Klartext einfügen","Paste plain","plain")] {
            let button=gtk::Button::with_label(ui.lang.text(de,en));let weak=Rc::downgrade(&editor);let popover=clipboard_popover.clone();let outer=more_popover.clone();
            button.connect_clicked(move |_| {popover.popdown();outer.popdown();if let Some(editor)=weak.upgrade(){editor.clipboard_command(action);}});clipboard_box.append(&button);
        }
        clipboard_popover.set_child(Some(&clipboard_box));clipboard_menu.set_popover(Some(&clipboard_popover));
        clipboard_menu.set_tooltip_text(Some("Ctrl+C · Ctrl+X · Ctrl+V · Ctrl+Shift+V"));more_box.append(&clipboard_menu);
        let image_menu=gtk::MenuButton::builder().label(ui.lang.text("Bild", "Image")).build();
        let image_popover=gtk::Popover::new();let image_box=gtk::Box::new(gtk::Orientation::Vertical,4);
        for (de,en,action) in [("Bilder oder Dateien einfügen …","Insert images or files …","choose"),("Ausgewähltes Bild entfernen","Remove selected image","delete"),("Rücknahmedaten anzeigen …","Show recovery files …","recovery")] {
            let button=gtk::Button::with_label(ui.lang.text(de,en));let weak=Rc::downgrade(&editor);let popover=image_popover.clone();let outer=more_popover.clone();
            button.connect_clicked(move|_|{popover.popdown();outer.popdown();if let Some(editor)=weak.upgrade(){match action {"choose"=>asset_drop::choose(editor),"delete"=>editor.command("deleteImage"),_=>asset_ui::recovery(&editor)}}});image_box.append(&button);
        }
        image_popover.set_child(Some(&image_box));image_menu.set_popover(Some(&image_popover));more_box.append(&image_menu);
        let table_menu = gtk::MenuButton::builder()
            .label(ui.lang.text("Tabelle", "Table"))
            .build();
        let table_popover = gtk::Popover::new();
        let table_box = gtk::Box::new(gtk::Orientation::Vertical, 4);
        for (de, en, command) in [
            ("Tabelle einfügen …", "Insert table …", "insert"),
            ("Zeile darunter", "Row below", "rowAfter"),
            ("Zeile löschen", "Delete row", "deleteRow"),
            ("Spalte rechts", "Column right", "columnAfter"),
            ("Spalte löschen", "Delete column", "deleteColumn"),
            ("Linksbündig", "Align left", "alignLeft"),
            ("Zentriert", "Align center", "alignCenter"),
            ("Rechtsbündig", "Align right", "alignRight"),
        ] {
            let button = gtk::Button::with_label(ui.lang.text(de, en));
            let weak = Rc::downgrade(&editor);
            let closing=table_popover.clone();let outer=more_popover.clone();
            button.connect_clicked(move |_|{closing.popdown();outer.popdown();if let Some(editor)=weak.upgrade(){
                if command=="insert" {editor.insert_table();}
                else {editor.table_command(command);}
            }});
            table_box.append(&button);
        }
        table_popover.set_child(Some(&table_box));
        table_menu.set_popover(Some(&table_popover));

        let link_menu = gtk::MenuButton::builder().label("Link").build();
        let link_popover = gtk::Popover::new();
        let link_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let url = gtk::Entry::builder()
            .placeholder_text("https://…")
            .max_length(2048)
            .build();
        link_box.append(&url);
        let insert = gtk::Button::with_label(ui.lang.text("Link einfügen", "Insert link"));
        let weak = Rc::downgrade(&editor);
        insert.connect_clicked(move |_|{if let Some(editor)=weak.upgrade(){let value=url.text();if safe_link(&value){editor.command_value("link",&value);}else{editor.status.set_text(editor.text("Nur HTTP(S)- oder Mailto-Adresse oder interner #-Verweis. Externes Öffnen bleibt gesperrt.","Only HTTP(S) or mailto addresses or internal # references. External navigation stays blocked."));}}});
        link_box.append(&insert);
        link_popover.set_child(Some(&link_box));
        link_menu.set_popover(Some(&link_popover));
        toolbar.insert(&link_menu, -1);
        more_box.append(&table_menu);
        let table_button=chrome::icon("fastra-table-symbolic",ui.lang.text("Tabelle einfügen …","Insert table …"));
        let weak=Rc::downgrade(&editor);table_button.connect_clicked(move |_|{if let Some(editor)=weak.upgrade(){editor.insert_table();}});
        toolbar.insert(&table_button,-1);
        toolbar.insert(&more, -1);
        // Alle Aktionen bleiben über Tooltip und zugänglichen Namen auffindbar.
        // Breite Labelreihen werden wie auf dem Mac durch kompakte Symbole ersetzt.
        link_menu.set_label("");link_menu.set_icon_name("fastra-link-symbolic");link_menu.set_tooltip_text(Some("Link"));link_menu.update_property(&[gtk::accessible::Property::Label("Link")]);
        let weak = Rc::downgrade(&editor);
        manager.connect_script_message_received(Some("visualMarkdown"), move |_, value| {
            if let Some(editor) = weak.upgrade() {
                if let Some(json) = value.to_json(0).filter(|v| v.len() <= 3 * MAX_BYTES) {
                    if let Ok(value) = serde_json::from_str(&json) {
                        editor.message(value);
                    }
                }
            }
        });
        let weak = Rc::downgrade(&editor);
        manager.connect_script_message_received(Some("markdownCopy"), move |_, value| {
            if let Some(editor) = weak.upgrade() {
                if let Some(raw) = value.to_json(0).filter(|v|v.len()<=16*MAX_BYTES) {
                    if let Ok(payload) = serde_json::from_str(&raw) { editor.copy(payload);return; }
                }
                editor.clipboard_error("size");
                editor.evaluate("fastraVisual.cancelClipboard();return JSON.stringify(false);", |_| {});
            }
        });
        let page_html=page.html.clone();
        let weak = Rc::downgrade(&editor);
        editor.view.connect_load_changed(move |_,event|{
            if event!=webkit6::LoadEvent::Finished{return;}
            if let Some(editor)=weak.upgrade(){
                let configuration=page.configuration.clone();
                let boot=format!(r#"const config={configuration};
                    const root=document.getElementById('fastra-visual');
                    root.addEventListener('keydown',event=>{{
                      if(root.isContentEditable && !event.isComposing && event.ctrlKey && !event.altKey && !event.metaKey && ['z','y'].includes(event.key.toLowerCase())){{event.preventDefault();event.stopImmediatePropagation();document.execCommand(event.shiftKey || event.key.toLowerCase()==='y'?'redo':'undo');window.fastraVisual.flush();return;}}
                      if(root.isContentEditable && !event.isComposing && event.ctrlKey && event.shiftKey && event.key.toLowerCase()==='v'){{event.preventDefault();event.stopImmediatePropagation();window.fastraVisual.requestClipboardPaste(true);}}
                    }},true);
                    for(const type of ['paste','drop'])root.addEventListener(type,event=>{{
                      event.preventDefault();event.stopImmediatePropagation();
                      if(type==='drop')return;
                      window.webkit.messageHandlers.visualMarkdown.postMessage({{kind:'linuxPaste',session:config.session,bookmark:window.fastraVisual.bookmarkClipboard()}});
                    }},true);
                    await window.fastraEnhanceMarkdown?.(root);
                    await document.fonts.ready;
                    const ok=await window.fastraVisual.start(config);
                    return JSON.stringify({{ok,session:config.session}});"#);
                let weak=Rc::downgrade(&editor);editor.evaluate(&boot,move |result|{if let Some(editor)=weak.upgrade(){
                    if result.as_ref().is_some_and(|v|v["ok"]==true && v["session"]==editor.session){editor.ready.set(true);editor.refresh_outline();#[cfg(debug_assertions)] asset_ui::test_seed_clipboard(&editor);image_watch::start(&editor);if editor.images.borrow().warnings.is_empty(){editor.status.set_text("");}else{editor.status.set_text(editor.text("Rich-Markdown · einige Bilder konnten nicht geladen werden; Quellverweise bleiben erhalten.","Rich Markdown · some images could not be loaded; source references are retained."));}}
                    else {editor.fail("Rich-Editor konnte die Quelle nicht verlustfrei übernehmen.","Rich editor could not adopt the source losslessly.");}
                }});
            }
        });
        let weak = Rc::downgrade(&editor);
        editor.view.connect_web_process_terminated(move|_,_|{if let Some(editor)=weak.upgrade(){editor.fail("Rich-WebKit-Prozess beendet. Aktionen angehalten; Quelle und Ansicht nicht still verworfen.","Rich WebKit process ended. Actions held; source and view not silently discarded.");}});
        let weak = Rc::downgrade(&editor);
        glib::timeout_add_local_once(std::time::Duration::from_secs(130), move || {
            if let Some(editor) = weak.upgrade() {
                if editor.active.get() && !editor.ready.get() {
                    editor.fail("Rich-Editor konnte nicht rechtzeitig geladen werden. Quelle bleibt erhalten.","Rich editor did not load in time. Source is retained.");
                }
            }
        });
        if image_sources.0.is_empty(){editor.view.load_html(&page_html,Some(BASE));}else{
            let weak=Rc::downgrade(&editor);let content=page_html;
            crate::git_view::background(move||Ok(image_sources.load(&image_cancel)),move|result|{
                if let Some(editor)=weak.upgrade().filter(|e|e.current().is_some()){
                    if let Ok(cache)=result{let content=cache.versioned_html(&content);*editor.images.borrow_mut()=cache;editor.view.load_html(&content,Some(BASE));}
                }
            });
        }
        Ok(editor)
    }
    pub(super) fn show_find(&self) { if let Some(bar) = self.find.borrow().as_ref() { bar.show(); } }
    pub(super) fn find_next(&self, backwards: bool) { if let Some(bar) = self.find.borrow().as_ref() { bar.next(backwards); } }
    fn text(&self, de: &'static str, en: &'static str) -> &'static str {
        self.ui.upgrade().map_or(en, |ui| ui.lang.text(de, en))
    }
    fn bound(&self) -> Option<Rc<Document>> {
        let doc = self.document.upgrade()?;
        let ui = self.ui.upgrade()?;
        (self.active.get()
            && ui.window.is_visible()
            && ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc)))
        .then_some(doc)
    }
    fn current(&self) -> Option<Rc<Document>> {
        let doc = self.bound()?;
        (doc.revision.get() == self.revision.get()
            && buffer_text(&doc.buffer) == *self.expected.borrow())
        .then_some(doc)
    }
    fn fail(&self, de: &'static str, en: &'static str) {
        self.failed.set(true);
        self.status.set_text(self.text(de, en));
        self.view.evaluate_javascript(
            "document.getElementById('fastra-visual').contentEditable='false'",
            None,
            None,
            None::<&gio::Cancellable>,
            |_| {},
        );
    }
    fn accept(&self, markdown: &str, input_revision: u64) -> bool {
        let Some(doc) = self.current() else {
            self.fail(
                "Quelle inzwischen geändert. Rich-Inhalt bleibt erhalten; nicht überschrieben.",
                "Source changed meanwhile. Rich content is retained; nothing overwritten.",
            );
            return false;
        };
        if markdown.len() > MAX_BYTES || markdown.contains('\0') {
            self.fail("Rich-Inhalt überschreitet die Grenze oder enthält Nullzeichen. Nicht synchronisiert; Ansicht bleibt erhalten.","Rich content exceeds the limit or contains NUL. Not synchronized; view retained.");
            return false;
        }
        if crate::text_limits::validate(markdown, Language(false)).is_err() {
            self.fail("Rich-Ergebnis überschreitet die native Grenze von 64 KiB je Quellzeile. Nicht synchronisiert; sichtbarer Entwurf bleibt erhalten.", "Rich result exceeds the native limit of 64 KiB per source line. Not synchronized; the visible draft is retained.");
            return false;
        }
        if markdown != *self.expected.borrow() {
            let old = self.expected.borrow();
            let (prefix, suffix) = changed_range(&old, markdown);
            let start = old[..prefix].chars().count() as i32;
            let end = old[..old.len() - suffix].chars().count() as i32;
            let replacement = &markdown[prefix..markdown.len() - suffix];
            doc.buffer.begin_user_action();
            let mut begin = doc.buffer.iter_at_offset(start);
            let mut end = doc.buffer.iter_at_offset(end);
            doc.buffer.delete(&mut begin, &mut end);
            doc.buffer.insert(&mut begin, replacement);
            doc.buffer.end_user_action();
            drop(old);
            *self.expected.borrow_mut() = markdown.to_owned();
            self.revision.set(doc.revision.get());
        }
        self.input_revision.set(input_revision);
        self.refresh_outline();
        true
    }
    fn message(self: &Rc<Self>, value: Value) {
        if value["session"] != self.session || !self.active.get() {
            return;
        }
        match value["kind"].as_str() {
            Some("linuxPaste") => if let Some(bookmark) = value["bookmark"].as_str() { self.paste(bookmark.to_owned(), value["plain"].as_bool().unwrap_or(false)); },
            Some("clipboardError") => self.clipboard_error(value["reason"].as_str().unwrap_or("format")),
            Some("outlinePosition") => {
                if self.outline_stamp().is_some() && value["revision"].as_u64() == Some(self.input_revision.get()) {
                    if let Some(outline) = self.outline.borrow().as_ref() { outline.rich_position(value["index"].as_i64().filter(|n| *n >= 0).map(|n|n as usize)); }
                }
            }
            Some("viewport") => if self.focused() && value["revision"].as_u64()==Some(self.input_revision.get()) { if let Some(doc)=self.current() { viewport::remember(&doc,&value["viewport"]); } },
            Some("change") => {
                let Some(revision) = value["revision"].as_u64() else {
                    return;
                };
                if revision <= self.input_revision.get() {
                    return;
                }
                if self.failed.get()
                    || value["base"].as_str() != Some(self.expected.borrow().as_str())
                    || revision != self.input_revision.get() + 1
                {
                    self.fail("Rich-Synchronisation ist veraltet. Inhalt bleibt in dieser Ansicht erhalten.","Rich synchronization is stale. Content remains in this view.");
                    return;
                }
                let weak = Rc::downgrade(self);
                let change = value.clone();
                asset_ui::reconcile(self.clone(), &value, Box::new(move |ok| {
                    let Some(editor) = weak.upgrade() else { return; };
                    if ok && change["markdown"].as_str().is_some_and(|text|editor.accept(text, revision)) {
                        asset_ui::mark_accepted(&editor,&change);
                        asset_ui::finish_image(&editor, revision);
                    } else { editor.reject_image_change(change); }
                }));
            }
            Some("protectedFormat") => self.status.set_text(self.text(
                "Geschützten Inhalt bitte im Quelltext bearbeiten.",
                "Edit protected content in source mode.",
            )),
            Some("tableError") => self.status.set_text(self.text(
                "Tabellenbefehl für diese Auswahl nicht verfügbar.",
                "Table command unavailable for this selection.",
            )),
            _ => {}
        }
    }
    fn reject_image_change(self: &Rc<Self>, value: Value) {
        let Some(revision) = value["revision"].as_u64() else { return; };
        if self.current().is_none() || value["base"].as_str() != Some(self.expected.borrow().as_str()) {
            self.fail("Bildaktion veraltet; Ansicht erhalten. Rücknahmedaten prüfen.","Image action is stale; view retained. Inspect recovery data.");
            return;
        }
        let weak = Rc::downgrade(self);
        let before = self.expected.borrow().clone();
        self.evaluate(&format!("return JSON.stringify(fastraVisual.rollbackImageChange({},{}));",value["inputType"],json!(before)),move|result| {
            if let Some(editor) = weak.upgrade() {
                if result == Some(Value::Bool(true)) && *editor.expected.borrow() == before {
                    editor.input_revision.set(revision);
                    asset_ui::finish_image(&editor, revision);
                } else { editor.fail("Bildaktion konnte nicht rückgängig gemacht werden. Ansicht bleibt erhalten; nichts gespeichert.","Image action could not be rolled back. View retained; nothing saved."); }
            }
        });
    }
    fn clipboard_command(&self, action: &str) {
        if !self.ready.get() || self.busy.get() || self.failed.get() || !self.focused(){self.clipboard_error("stale");return;}
        let code=match action {
            "copy"=>"fastraVisual.requestClipboardCopy(false)","cut"=>"fastraVisual.requestClipboardCopy(true)",
            "plain"=>"fastraVisual.requestClipboardPaste(true)",_=>"fastraVisual.requestClipboardPaste(false)",
        };
        self.evaluate(&format!("{code};return JSON.stringify(true);"),|_|{});
    }
    fn clipboard_error(&self, reason: &str) {
        self.status.set_text(match reason {
            "busy" => self.text("Zwischenablage wird noch gelesen. Bitte kurz warten.","Clipboard is still being read. Please wait."),
            "size" => self.text("Zwischenablage überschreitet eine Sicherheitsgrenze: Text/HTML 2 MiB, ein Bild 32 MiB, Bilddaten insgesamt 64 MiB, höchstens 32 Dateien oder 20.000 HTML-Knoten. Nicht eingefügt.","Clipboard exceeds a safety limit: text/HTML 2 MiB, one image 32 MiB, image data total 64 MiB, at most 32 files or 20,000 HTML nodes. Nothing inserted."),
            "encoding" => self.text("Zwischenablage enthält kein gültiges UTF-8 oder enthält Nullzeichen. Nichts eingefügt.","Clipboard is not valid UTF-8 or contains NUL characters. Nothing inserted."),
            "read" => self.text("Zwischenablage konnte nicht gelesen werden. Nichts eingefügt.","Clipboard could not be read. Nothing inserted."),
            "rtfd" => self.text("RTFD-Dateipakete bitte als lokale Datei öffnen oder ablegen. Undokumentierte Zwischenablagepakete werden nicht in Klartext umgewandelt.","Open or drop RTFD as a local file package. Undocumented clipboard packages are not converted to plain text."),
            "images" => self.text("Bilddaten fehlen, sind nicht geprüft oder können nicht sicher übernommen werden. Nichts eingefügt.","Image data is missing, unverified or cannot be imported safely. Nothing inserted."),
            "stale"|"changed" => self.text("Zwischenablage, Dokument oder Einfügestelle geändert. Nichts eingefügt.","Clipboard, document or insertion target changed. Nothing inserted."),
            "timeout" => self.text("Zwischenablage antwortet nicht rechtzeitig. Nichts eingefügt.","Clipboard did not respond in time. Nothing inserted."),
            _ => self.text("Zwischenablageformat oder Linkadresse nicht unterstützt. Nichts eingefügt.","Clipboard format or link address is unsupported. Nothing inserted."),
        });
    }
    fn focused(&self) -> bool {
        let Some(doc) = self.current() else {
            return false;
        };
        self.ui
            .upgrade()
            .is_some_and(|ui| ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)))
    }
    fn copy(self: &Rc<Self>, value: Value) {
        if value["imageSources"].as_array().is_some_and(|values|!values.is_empty()) {asset_copy::copy(self.clone(),value); return;}
        let bookmark = value["bookmark"].as_str().unwrap_or("");
        let valid = value["session"] == self.session
            && self.focused()
            && ["plain", "html", "markdown"].iter().all(|key| {
                value[*key]
                    .as_str()
                    .is_some_and(|s| s.len() <= MAX_BYTES && !s.contains('\0'))
            });
        let success = if valid {
            let plain = value["plain"].as_str().unwrap();
            let html = value["html"].as_str().unwrap();
            let markdown = value["markdown"].as_str().unwrap();
            let payload = json!({"markdown":markdown,"url":"","images":""}).to_string();
            let payload_bytes = payload.len();
            let providers = [
                gtk::gdk::ContentProvider::for_value(&plain.to_value()),
                gtk::gdk::ContentProvider::for_bytes(
                    "text/html",
                    &glib::Bytes::from_owned(html.as_bytes().to_vec()),
                ),
                gtk::gdk::ContentProvider::for_bytes(
                    clipboard::MIME,
                    &glib::Bytes::from_owned(payload.into_bytes()),
                ),
            ];
            payload_bytes <= MAX_BYTES
                && self
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                    .is_ok()
        } else {
            false
        };
        if !success {
            self.clipboard_error(if valid { "read" } else { "size" });
        }
        self.evaluate(
            &format!(
                "return JSON.stringify(fastraVisual.completeClipboard({},{},{}));",
                json!(bookmark),
                value["cut"] == true && valid,
                success
            ),
            |_| {},
        );
    }
    fn paste(self: &Rc<Self>, bookmark: String, plain: bool) {
        if !self.ready.get()
            || self.busy.get()
            || self.failed.get()
            || !self.focused()
            || self.clipboard_busy.get()
        {
            self.clipboard_error(if self.clipboard_busy.get() {
                "busy"
            } else {
                "stale"
            });
            self.evaluate(
                &format!(
                    "fastraVisual.discardBookmark({});return JSON.stringify(false);",
                    json!(bookmark)
                ),
                |_| {},
            );
            return;
        }
        self.clipboard_busy.set(true);
        self.clipboard_request.set(self.clipboard_request.get() + 1);
        let request = self.clipboard_request.get();
        let operation = self.operation.get();
        let revision = self.revision.get();
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let generation = ui.generation.get();
        let clipboard = self.view.clipboard();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let incoming = clipboard::read(clipboard, plain).await;
            let Some(editor) = weak.upgrade() else {
                return;
            };
            editor.clipboard_busy.set(false);
            let current = editor.clipboard_request.get() == request
                && editor.operation.get() == operation
                && editor.revision.get() == revision
                && editor.focused()
                && editor
                    .ui
                    .upgrade()
                    .is_some_and(|ui| ui.generation.get() == generation);
            if !current {
                editor.clipboard_error("stale");
                editor.evaluate(
                    &format!(
                        "fastraVisual.discardBookmark({});return JSON.stringify(false);",
                        json!(bookmark)
                    ),
                    |_| {},
                );
                return;
            }
            let code=match incoming {
                Ok(clipboard::Incoming::Assets(assets)) => { asset_ui::receive(editor, assets, bookmark); return; },
                Ok(clipboard::Incoming::Text(text)) => format!("return JSON.stringify({{ok:fastraVisual.insertClipboardText({},{}),reason:'stale'}});",json!(bookmark),json!(text)),
                Ok(clipboard::Incoming::Html(html)) => {asset_ui::html(editor,html,bookmark);return;},
                Ok(clipboard::Incoming::Markdown(markdown)) => {
                    match page(&markdown,&glib::uuid_string_random(),false,false) {
                        Ok(page) => format!("return JSON.stringify({{ok:fastraVisual.insertBookmarked({},{},{},null,[],false),reason:'stale'}});",json!(bookmark),json!(page.fragment),page.configuration["opaqueSources"]),
                        Err(_) => {editor.clipboard_error("size");editor.evaluate(&format!("fastraVisual.discardBookmark({});return JSON.stringify(false);",json!(bookmark)), |_|{});return;}
                    }
                }
                Err(reason) => {editor.clipboard_error(reason);editor.evaluate(&format!("fastraVisual.discardBookmark({});return JSON.stringify(false);",json!(bookmark)), |_|{});return;}
            };
            let weak = Rc::downgrade(&editor);
            editor.evaluate(&code, move |result| {if let Some(editor)=weak.upgrade(){if !result.as_ref().is_some_and(|v|v["ok"]==true){editor.clipboard_error(result.as_ref().and_then(|v|v["reason"].as_str()).unwrap_or("format"));}else{editor.status.set_text("");}}});
        });
    }
    pub fn evaluate(&self, code: &str, done: impl FnOnce(Option<Value>) + 'static) {
        self.view.call_async_javascript_function(
            code,
            None,
            None,
            Some(BASE),
            None::<&gio::Cancellable>,
            move |result| {
                let value = result
                    .ok()
                    .and_then(|v| serde_json::from_str(&v.to_str()).ok());
                done(value);
            },
        );
    }
    pub fn command(&self, command: &str) {
        if !self.ready.get()
            || self.busy.get()
            || (self.failed.get() && !matches!(command, "undo" | "redo"))
            || self.current().is_none()
        {
            return;
        }
        let body = if matches!(command, "undo" | "redo") {
            format!("document.getElementById('fastra-visual').focus(); document.execCommand({}); window.fastraVisual.flush(); return JSON.stringify(true);",json!(command))
        } else {
            format!(
                "window.fastraVisual.command({}); return JSON.stringify(true);",
                json!(command)
            )
        };
        self.evaluate(&body, |_| {});
    }
    fn command_value(&self, command: &str, value: &str) {
        if !self.ready.get() || self.busy.get() || self.failed.get() || self.current().is_none() {
            return;
        }
        self.evaluate(
            &format!(
                "fastraVisual.command({},{}); return JSON.stringify(true);",
                json!(command),
                json!(value)
            ),
            |_| {},
        );
    }
    fn insert_table(self:&Rc<Self>) {
        let Some(ui)=self.ui.upgrade() else {return;};
        if !self.ready.get()||self.busy.get()||self.failed.get()||!self.focused(){return;}
        let weak=Rc::downgrade(self);let revision=self.revision.get();let input=self.input_revision.get();let operation=self.operation.get();let generation=ui.generation.get();
        super::markdown_inline::table_prompt(&ui.window,ui.lang,move|columns,header|{
            if let Some(editor)=weak.upgrade(){
                if !editor.active.get()||!editor.focused()||editor.revision.get()!=revision||editor.input_revision.get()!=input||editor.operation.get()!=operation||editor.ui.upgrade().is_none_or(|ui|ui.generation.get()!=generation){return;}
                let head=format!("<tr>{}</tr>","<th><br></th>".repeat(columns));
                let row=format!("<tr>{}</tr>","<td><br></td>".repeat(columns));
                editor.command_value("insertTable",&format!("<table data-md-table=\"gfm\"><thead>{head}</thead><tbody>{row}{}</tbody></table><p><br></p>",if header {""}else{&row}));
            }
        });
    }
    fn table_command(self: &Rc<Self>, command: &str) {
        if !self.ready.get() || self.busy.get() || self.failed.get() || self.current().is_none() {
            return;
        }
        let weak = Rc::downgrade(self);
        self.evaluate(
            &format!(
                "return JSON.stringify(fastraVisual.tableCommand({},'',null));",
                json!(command)
            ),
            move |result| {
                if let Some(editor) = weak.upgrade() {
                    if editor.active.get() && !result.is_some_and(|v| v["ok"] == true) {
                        editor.status.set_text(editor.text(
                            "Tabellenbefehl für diese Auswahl nicht verfügbar.",
                            "Table command unavailable for this selection.",
                        ));
                    }
                }
            },
        );
    }
    pub fn synchronize(self: &Rc<Self>, hold: bool, done: Completion) {
        if !self.active.get() {
            done(true);
            return;
        }
        if !self.ready.get() || self.busy.get() || self.current().is_none() {
            self.status.set_text(self.text(
                "Rich-Synchronisation noch nicht bereit oder Quelle geändert. Aktion angehalten.",
                "Rich synchronization not ready or source changed. Action held.",
            ));
            done(false);
            return;
        }
        self.busy.set(true);
        let operation = self.operation.get() + 1;
        self.operation.set(operation);
        let completion = Rc::new(RefCell::new(Some(done)));
        let weak = Rc::downgrade(self);
        let completed = completion.clone();
        let code = format!(
            "return JSON.stringify({{...window.fastraVisual.prepareAction(),session:{}}});",
            json!(self.session)
        );
        self.evaluate(&code, move |result| {
            let Some(editor) = weak.upgrade() else { if let Some(done) = completed.borrow_mut().take() { done(false); } return; };
            if editor.operation.get() != operation { if let Some(done)=completed.borrow_mut().take(){done(false);} return; }
            editor.busy.set(false);
            let valid = result.as_ref().is_some_and(|value| value["session"] == editor.session
                && !value["composing"].as_bool().unwrap_or(false)
                && value["revision"].as_u64().is_some_and(|revision|revision >= editor.input_revision.get())
                && value["markdown"].as_str().is_some());
            let value = result.unwrap_or(Value::Null);
            let finish_editor = editor.clone();
            let finish_value = value.clone();
            let finish: Box<dyn FnOnce(bool)> = Box::new(move |assets_ok| {
                let editor = finish_editor;
                let ok = assets_ok && editor.operation.get() == operation && finish_value["revision"].as_u64().zip(finish_value["markdown"].as_str()).is_some_and(|(revision,text)| editor.accept(text,revision));
                if !ok { editor.fail("Rich-Änderungen konnten nicht synchronisiert werden. Aktion angehalten; Ansicht bleibt erhalten.","Rich changes could not be synchronized. Action held; view retained."); }
                else { asset_ui::mark_accepted(&editor,&finish_value); if let Some(doc) = editor.current() { viewport::remember(&doc, &finish_value["viewport"]); } editor.failed.set(false); }
                if !hold || !ok { editor.release(); }
                if let Some(done) = completed.borrow_mut().take() { done(ok); }
            });
            if valid { asset_ui::reconcile(editor, &value, finish); } else { finish(false); }
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_secs(10), move || {
            if let Some(editor) = weak.upgrade() {
                if let Some(done) = completion.borrow_mut().take() {
                    if editor.operation.get()==operation {
                        editor.operation.set(editor.operation.get() + 1);
                        editor.busy.set(false);
                        editor.fail("Rich-Editor antwortet nicht. Aktion angehalten; ungesicherte Ansicht erhalten.","Rich editor did not respond. Action held; unsaved view retained.");
                    }
                    done(false);
                }
            }
        });
    }
    pub(super) fn ready_for_saved_source(&self) -> bool {
        self.ready.get() && !self.busy.get() && !self.failed.get() && self.current().is_some()
    }
    pub(super) fn pending(&self) -> bool { self.busy.get() || self.clipboard_busy.get() }
    pub(super) fn close_stamp(&self) -> CloseStamp {
        (self.ready.get(),self.active.get(),self.busy.get(),self.failed.get(),self.revision.get(),self.input_revision.get(),self.operation.get(),self.clipboard_request.get(),self.clipboard_busy.get())
    }
    pub fn release(&self) {
        if self.failed.get() {
            return;
        }
        let code = format!(
            "window.fastraVisual.completeAction({}); return JSON.stringify(true);",
            json!(self.session)
        );
        self.evaluate(&code, |_| {});
    }
}

fn source_controls(options: &gtk::FlowBox, toggle: &gtk::CheckButton, enabled: bool) {
    let mut child = options.first_child();
    while let Some(widget) = child {
        if !toggle.is_ancestor(&widget) {
            widget.set_sensitive(enabled);
        }
        child = widget.next_sibling();
    }
}
pub fn install(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    source: &gtk::Paned,
    options: &gtk::FlowBox,
) -> gtk::Stack {
    asset_refs::register(ui);
    let stack = gtk::Stack::new();
    stack.set_vexpand(true);
    stack.add_named(source, Some("source"));
    let toggle = gtk::CheckButton::with_label(ui.lang.text("Rich-Markdown", "Rich Markdown"));
    *doc.rich_toggle.borrow_mut() = Some(toggle.clone());
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let stack_copy = stack.clone();
    let source_options = options.clone();
    let previous_preview = Rc::new(Cell::new(None::<(u64, bool)>));
    let source_display=mode::SourceDisplay::new(&stack,&source_options,&toggle,previous_preview.clone());
    toggle.connect_toggled(move |toggle| {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return;
        };
        let manual=!doc.markdown_visual_programmatic.replace(false);
        if toggle.is_active() {
            if doc.rich.borrow().is_some() {
                return;
            }
            if doc.is_read_only() || doc.saving.get() {
                toggle.set_active(false);
                return;
            }
            match RichEditor::new(&ui, &doc) {
                Ok(editor) => {
                    *editor.source_display.borrow_mut()=Some(source_display.clone());
                    if manual {doc.markdown_visual_override.set(Some(true));}
                    previous_preview.set(doc.markdown_toggle.borrow().as_ref().map(|preview| (doc.revision.get(), preview.is_active())));
                    stack_copy.add_named(&editor.widget, Some("rich"));
                    stack_copy.set_visible_child_name("rich");
                    let discard=gtk::Button::with_label(ui.lang.text("Rich-Ansicht verwerfen …","Discard rich view …"));
                    discard.set_tooltip_text(Some(ui.lang.text("Nur nach Bestätigung: zum aktuellen Quellpuffer wechseln; nicht synchronisierte Rich-Eingaben gehen verloren.","After confirmation only: return to the current source buffer; unsynchronized rich input is lost.")));
                    let source_display=source_display.clone();let weak_editor=Rc::downgrade(&editor);let weak_doc=Rc::downgrade(&doc);let weak_ui=Rc::downgrade(&ui);
                    discard.connect_clicked(move |_|{
                        let (Some(editor),Some(doc),Some(ui))=(weak_editor.upgrade(),weak_doc.upgrade(),weak_ui.upgrade())else{return;};
                        if editor.busy.get()||doc.saving.get(){return;}
                        let dialog=gtk::AlertDialog::builder().message(ui.lang.text("Nicht synchronisierte Rich-Eingaben verwerfen?","Discard unsynchronized rich input?"))
                            .detail(ui.lang.text("Der aktuelle Quellpuffer bleibt erhalten. Noch nicht übernommene Eingaben dieser Rich-Ansicht gehen verloren.","The current source buffer is retained. Input not yet accepted from this rich view is lost."))
                            .buttons([ui.lang.text("Abbrechen","Cancel"),ui.lang.text("Rich-Ansicht verwerfen","Discard rich view")]).cancel_button(0).default_button(0).build();
                        let source_display=source_display.clone();
                        let parent=ui.window.clone();
                        dialog.choose(Some(&parent),None::<&gio::Cancellable>,move|result|{
                            if result!=Ok(1)||editor.busy.get()||!doc.rich.borrow().as_ref().is_some_and(|current|Rc::ptr_eq(current,&editor)){return;}
                            source_display.show(&ui,&doc,&editor,editor.revision.get(),true);
                        });
                    });
                    editor.more.append(&discard);
                    let popover=editor.more.ancestor(gtk::Popover::static_type()).and_then(|parent|parent.downcast::<gtk::Popover>().ok());
                    discard.connect_clicked(move |_| {if let Some(popover)=popover.as_ref(){popover.popdown();}});
                    *doc.rich.borrow_mut() = Some(editor);
                    source_controls(&source_options,toggle,false);
                    if let Some(preview) = doc.markdown_toggle.borrow().as_ref() {
                        preview.set_active(false);
                        preview.set_sensitive(false);
                    }
                    ui.search_section.set_expanded(false);
                    ui.invalidate();
                }
                Err(error) => {
                    ui.status.set_text(&error);
                    toggle.set_active(false);
                }
            }
        } else {
            let Some(editor) = doc.rich.borrow().clone() else {
                return;
            };
            toggle.set_sensitive(false);
            let toggle = toggle.clone();
            let source_display=source_display.clone();
            let doc = doc.clone();
            let ui = ui.clone();
            let held = editor.clone();
            let expected_revision=doc.revision.get();
            let request_operation=(editor.active.get() && editor.ready.get() && !editor.busy.get() && editor.current().is_some()).then(||editor.operation.get()+1);
            editor.synchronize(
                true,
                Box::new(move |ok| {
                    let restore=held.clone();
                    let finish: Box<dyn FnOnce(bool)> = Box::new(move |ok| {
                    let owner=doc.rich.borrow().as_ref().is_some_and(|current|Rc::ptr_eq(current,&held)) && request_operation.is_none_or(|operation|held.operation.get()==operation);
                    let ok=ok && owner && source_display.show(&ui,&doc,&held,expected_revision,manual);
                    if owner { toggle.set_sensitive(true); if !ok { toggle.set_active(true); } }
                    if !ok && request_operation.is_some_and(|operation|held.operation.get()==operation) { held.release(); }
                    let done = held.navigation_source_completion.borrow_mut().take();
                    if let Some(done) = done { done(ok); }
                    });
                    if ok { asset_ui::for_source(restore,finish); } else { finish(false); }
                }),
            );
        }
    });
    options.insert(&toggle, -1);
    stack
}

fn synchronize_all(editors: Rc<Vec<Rc<RichEditor>>>, index: usize, done: Completion) {
    if index == editors.len() {
        done(true);
        return;
    }
    let editor = editors[index].clone();
    editor.synchronize(
        true,
        Box::new(move |ok| {
            if ok {
                synchronize_all(editors, index + 1, done);
            } else {
                for editor in editors.iter() {
                    editor.release();
                }
                done(false);
            }
        }),
    );
}
pub fn drop_files_at(ui:&Rc<Ui>,files:&[gio::File],x:f64,y:f64)->bool{
    ui.active().and_then(|doc|doc.rich.borrow().clone()).filter(|editor|editor.active.get()).is_some_and(|editor|asset_drop::files_at(editor,files,x,y))
}
pub fn after_save(doc:&Rc<Document>){
    let Some(editor)=doc.rich.borrow().clone().filter(|editor|editor.active.get() && !editor.busy.get() && !editor.failed.get())else{return;};
    let weak=Rc::downgrade(&editor);
    editor.evaluate("return JSON.stringify(fastraVisual.clipboardState());",move|value|{
        let Some(editor)=weak.upgrade()else{return;};
        if let Some(value)=value.filter(|value|value["revision"].as_u64()==Some(editor.input_revision.get()) && value["markdown"].as_str()==Some(editor.expected.borrow().as_str())){
            let weak=Rc::downgrade(&editor);asset_ui::reconcile_saved(editor,&value,Box::new(move|ok|{if let Some(editor)=weak.upgrade(){if !ok{editor.status.set_text(editor.text("Datei gespeichert; Bildrücknahme angehalten. Rücknahmedaten im Bildmenü prüfen.","File saved; image cleanup held. Inspect recovery files in Image menu."));}}}));
        }
    });
}
pub fn release_all(ui: &Ui) {
    for doc in ui.documents.borrow().iter() {
        if let Some(editor) = doc.rich.borrow().as_ref() {
            editor.release();
        }
    }
}
pub(super) struct CloseFences {
    cancelled: Cell<bool>,
    held: RefCell<Vec<(std::rc::Weak<RichEditor>,u64)>>,
}
impl CloseFences {
    pub(super) fn new()->Rc<Self>{Rc::new(Self{cancelled:Cell::new(false),held:RefCell::new(Vec::new())})}
    pub(super) fn cancel(&self){
        self.cancelled.set(true);
        for (editor,operation) in self.held.borrow().iter(){
            if let Some(editor)=editor.upgrade().filter(|editor|editor.operation.get()==*operation){editor.release();}
        }
    }
}
pub(super) fn remember_save_fence(doc: &Document) -> Option<Rc<CloseFences>> {
    doc.line_endings.pending()?;
    let editor = doc.rich.borrow().clone().filter(|editor| editor.active.get())?;
    let fences = CloseFences::new();
    fences.held.borrow_mut().push((Rc::downgrade(&editor), editor.operation.get()));
    Some(fences)
}
pub(super) fn hold_for_close(fences: Rc<CloseFences>, editor: Rc<RichEditor>, done: Box<dyn FnOnce(bool)>) {
    if fences.cancelled.get() { done(false); return; }
    fences.held.borrow_mut().push((Rc::downgrade(&editor), editor.operation.get().wrapping_add(1)));
    editor.synchronize(true, Box::new(move |ok| {
        if ok && !fences.cancelled.get() { done(true); }
        else { fences.cancel(); done(false); }
    }));
}
pub(super) fn flush_close(ui:&Rc<Ui>,fences:Rc<CloseFences>,done:Completion){
    let editors=Rc::new(ui.documents.borrow().iter().filter_map(|doc|doc.rich.borrow().clone()).filter(|editor|editor.active.get()).collect());
    flush_close_at(editors,0,fences,done);
}
fn flush_close_at(editors:Rc<Vec<Rc<RichEditor>>>,index:usize,fences:Rc<CloseFences>,done:Completion){
    if fences.cancelled.get(){fences.cancel();done(false);return;}
    let Some(editor)=editors.get(index).cloned()else{done(true);return;};
    let run=move||{
        if fences.cancelled.get(){fences.cancel();done(false);return;}
        fences.held.borrow_mut().push((Rc::downgrade(&editor),editor.operation.get()+1));
        editor.synchronize(true,Box::new(move|ok|{
            if ok && !fences.cancelled.get(){flush_close_at(editors,index+1,fences,done);}else{fences.cancel();done(false);}
        }));
    };
    #[cfg(debug_assertions)]
    if let Ok(value)=std::env::var("FASTRA_QUIT_TEST_DELAY_RICH_MS"){
        assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),Ok("1"));
        let millis:u64=value.parse().unwrap();assert!(millis<=3000);
        glib::timeout_add_local_once(Duration::from_millis(millis),run);return;
    }
    run();
}
pub(super) fn flush_documents_owned(documents: &[Rc<Document>], done: Completion) {
    let mut editors = Vec::new();
    for document in documents {
        if let Some(editor) = document.rich.borrow().clone().filter(|editor| editor.active.get()) {
            if !editors.iter().any(|old| Rc::ptr_eq(old, &editor)) {
                editors.push(editor);
            }
        }
    }
    let editors = Rc::new(editors);
    let held = editors.clone();
    synchronize_all(editors, 0, Box::new(move |ok| {
        done(ok);
        for editor in held.iter() { editor.release(); }
    }));
}

pub fn flush_all_owned(ui: &Rc<Ui>, hold: bool, done: Box<dyn FnOnce(bool)>) {
    let editors = ui
        .documents
        .borrow()
        .iter()
        .filter_map(|doc| doc.rich.borrow().clone())
        .filter(|e| e.active.get())
        .collect();
    let weak = Rc::downgrade(ui);
    synchronize_all(
        Rc::new(editors),
        0,
        Box::new(move |ok| {
            done(ok);
            if !hold || !ok {
                if let Some(ui) = weak.upgrade() {
                    release_all(&ui);
                }
            }
        }),
    );
}

#[cfg(debug_assertions)]
fn capture(
    window: &gtk::ApplicationWindow,
    name: &str,
    state: &RefCell<Option<mpsc::Receiver<bool>>>,
) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_RICH_SCREENSHOTS") else {
        return true;
    };
    let pending = state.borrow().as_ref().map(mpsc::Receiver::try_recv);
    if let Some(result) = pending {
        match result {
            Ok(success) => assert!(success, "Rich screenshot failed"),
            Err(mpsc::TryRecvError::Empty) => return false,
            Err(_) => panic!("Screenshot worker stopped"),
        }
    } else {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory).unwrap();
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

fn mode_toggle(doc: &Document, _lang: Language) -> gtk::CheckButton {
    doc.rich_toggle
        .borrow()
        .clone()
        .expect("Rich Markdown control is installed")
}
#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_RICH_CODE_SELFTEST").is_some() { code_gui_test::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_FORMATTING_SELFTEST").is_some() {formatting_test::run(ui);return;}
    if std::env::var_os("FASTRA_RICH_FIND_SELFTEST").is_some() { find::selftest::run(ui); return; }
    if std::env::var_os("FASTRA_AUTOLINK_SELFTEST").is_some() { autolink_gui_test::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_MATH_SELFTEST").is_some() { math_gui_test::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_BLANK_CLIPBOARD_SELFTEST").is_some() { blank_lines_clipboard_gui_test::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_BLANK_LINES_SELFTEST").is_some() { blank_lines_gui_test::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_IMAGE_WATCH_SELFTEST").is_some() { image_watch_gui_test::run(ui);return; }
    if std::env::var_os("FASTRA_RTF_REAL_IMPORT").is_some() { crate::import_view::start_rtf_test(ui); return; }
    if std::env::var_os("FASTRA_RICH_ASSET_SELFTEST").is_some() { asset_gui::run(ui); return; }
    if std::env::var_os("FASTRA_RICH_OUTLINE_SELFTEST").is_some() { navigation::run_selftest(ui);return; }
    if std::env::var_os("FASTRA_RICH_CLIPBOARD_SELFTEST").is_some() { gui_test::run(ui);return; }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_RICH_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1180),
        850,
    );
    let root = std::path::PathBuf::from(
        std::env::var_os("FASTRA_RICH_TEST_ROOT").expect("private synthetic fixture root"),
    );
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("rich.md");
    let reopen = std::env::var_os("FASTRA_RICH_REOPEN").is_some();
    let original="# Rich gate\r\n\r\nAlpha\u{a0}Beta 😀.\r\n\r\n- first\n- second\n\n| Name | Value |\n| --- | --- |\n| Ä | 1 |\n\n```mermaid\ngraph LR; A-->B\n```\n\n<script>globalThis.bad = true</script>\n";
    if !reopen {
        let mut bytes = b"\xef\xbb\xbf".to_vec();
        bytes.extend(original.as_bytes());
        std::fs::write(&path, bytes).unwrap();
    }
    let stage = Cell::new(0);
    let response = Rc::new(RefCell::new(None::<Value>));
    let captures = RefCell::new(None);
    let before = RefCell::new(String::new());
    let editor_held = RefCell::new(None::<Rc<RichEditor>>);
    let started = std::time::Instant::now();
    glib::timeout_add_local(std::time::Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < std::time::Duration::from_secs(90),
            "Rich stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let current = || ui.active().unwrap();
        match stage.get() {
            0 => {
                ui.load_path(path.clone());
                stage.set(1);
            }
            1 => {
                if current().name != "rich.md" {
                    return glib::ControlFlow::Continue;
                }
                mode_toggle(&current(), ui.lang).set_active(true);
                stage.set(2);
            }
            2 => {
                let Some(editor) = current().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!editor.failed.get(), "{}", editor.status.text());
                if !editor.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                *editor_held.borrow_mut() = Some(editor.clone());
                let reply = response.clone();
                editor.evaluate("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))); return JSON.stringify({text:document.getElementById('fastra-visual').innerText, source:fastraVisual.markdown(), bad:typeof globalThis.bad, protected:document.querySelectorAll('[data-md-opaque]').length});",move|result|{*reply.borrow_mut()=result;});
                stage.set(3);
            }
            3 => {
                if response.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                if !capture(&ui.window, "rich-initial", &captures) {
                    return glib::ControlFlow::Continue;
                }
                let Some(result) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(result["bad"], "undefined");
                assert!(result["protected"].as_u64().unwrap() >= 2);
                assert_eq!(
                    result["source"].as_str().unwrap(),
                    buffer_text(&current().buffer)
                );
                let editor = editor_held.borrow().clone().unwrap();
                let reply = response.clone();
                if reopen {
                    assert!(result["text"].as_str().unwrap().contains("Ω\u{a0}雪"));
                    *before.borrow_mut() = buffer_text(&current().buffer);
                    editor.evaluate("await new Promise(resolve=>setTimeout(resolve,200));const p=document.querySelector('#fastra-visual p');const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,' LATE');return JSON.stringify(true);",move|v|{*reply.borrow_mut()=v;});
                    let doc = current();
                    let mut end = doc.buffer.end_iter();
                    doc.buffer.insert(&mut end, "EXTERNAL SOURCE");
                    ui.tabs.set_current_page(Some(0));
                    stage.set(10);
                } else {
                    editor.evaluate("const p=document.querySelector('#fastra-visual p');const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('bold');return JSON.stringify(fastraVisual.markdown());",move|v|{*reply.borrow_mut()=v;});
                    stage.set(4);
                }
            }
            4 => {
                if response.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(buffer_text(&current().buffer).contains("**Alpha**"));
                editor_held.borrow().as_ref().unwrap().command("undo");
                stage.set(11);
            }
            11 => {
                if buffer_text(&current().buffer).contains("**Alpha**") {
                    return glib::ControlFlow::Continue;
                }
                editor_held.borrow().as_ref().unwrap().command("redo");
                stage.set(12);
            }
            12 => {
                if !buffer_text(&current().buffer).contains("**Alpha**") {
                    return glib::ControlFlow::Continue;
                }
                let editor = editor_held.borrow().clone().unwrap();
                let reply = response.clone();
                editor.evaluate("const cell=document.querySelector('#fastra-visual td');const r=document.createRange();r.selectNodeContents(cell);getSelection().removeAllRanges();getSelection().addRange(r);const result=fastraVisual.tableCommand('pasteCell','Ω\\u00a0雪',null);return JSON.stringify(result);",move|v|{*reply.borrow_mut()=v;});
                stage.set(5);
            }
            5 => {
                let Some(result) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(result["ok"], true);
                ui.save_document();
                mode_toggle(&current(), ui.lang).set_active(false);
                assert!(
                    current().rich.borrow().is_some(),
                    "Pending sync must retain rich mode"
                );
                stage.set(6);
            }
            6 => {
                let disk = std::fs::read(&path).unwrap();
                let body = std::str::from_utf8(&disk[3..]).unwrap();
                if current().saving.get() || !body.contains("**Alpha**") || !body.contains("雪") {
                    return glib::ControlFlow::Continue;
                }
                assert!(disk.starts_with(b"\xef\xbb\xbf"));
                assert!(body.contains("```mermaid\ngraph LR; A-->B\n```"));
                assert!(body.contains("<script>globalThis.bad = true</script>"));
                if !capture(&ui.window, "rich-saved", &captures) {
                    return glib::ControlFlow::Continue;
                }
                mode_toggle(&current(), ui.lang).set_active(false);
                stage.set(7);
            }
            7 => {
                if current().rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let old = editor_held.borrow().clone().unwrap();
                let source = buffer_text(&current().buffer);
                old.message(json!({"kind":"change","session":old.session,"base":source,"markdown":"STALE MODE","revision":999}));
                assert_eq!(buffer_text(&current().buffer), source);
                mode_toggle(&current(), ui.lang).set_active(true);
                stage.set(8);
            }
            8 => {
                let Some(editor) = current().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!editor.failed.get(), "{}", editor.status.text());
                if !editor.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS Rich roundtrip: real WebKit formatting/undo/redo/table/NBSP/Unicode, BOM/protected source preservation, Save synchronization, pending mode switch held, stale mode ignored; closing through synchronized clean-window path");
                ui.window.close();
                stage.set(9);
            }
            9 => {}
            10 => {
                if response.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let editor = editor_held.borrow().clone().unwrap();
                if !editor.failed.get() {
                    return glib::ControlFlow::Continue;
                }
                let doc = editor.document.upgrade().unwrap();
                assert!(buffer_text(&doc.buffer).ends_with("EXTERNAL SOURCE"));
                assert!(!buffer_text(&current().buffer).contains("LATE"));
                ui.tabs.set_current_page(Some(
                    ui.documents
                        .borrow()
                        .iter()
                        .position(|d| Rc::ptr_eq(d, &doc))
                        .unwrap() as u32,
                ));
                if !capture(&ui.window, "rich-stale", &captures) {
                    return glib::ControlFlow::Continue;
                }
                let expected = std::fs::read(&path).unwrap();
                ui.tabs.set_current_page(Some(
                    ui.documents
                        .borrow()
                        .iter()
                        .position(|d| Rc::ptr_eq(d, &doc))
                        .unwrap() as u32,
                ));
                ui.save_document();
                assert_eq!(std::fs::read(&path).unwrap(), expected);
                println!("PASS Rich fresh-process reopen: persisted NBSP/table formatting; unsafe script inert; delayed real JavaScript change bound to original document and rejected after external revision; Save held with bytes preserved");
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

impl Drop for RichEditor {fn drop(&mut self){self.image_cancel.cancel();}}

#[cfg(test)]
mod tests {
    use super::*;
    fn check_global_reference_destinations(prefix: &str) {
        let directory=tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("pic.png"), include_bytes!("../tests/fixtures/pixel-1.png")).unwrap();
        let source=format!("See [link][r] {prefix}![picture][p]\n  \nAfter\n\n[r]: https://example.invalid/\n[p]: pic.png\n");
        let sources=images::Sources::collect(&source,Some(&directory.path().join("refs.md")),"refs").unwrap();
        assert!(sources.0.contains_key("pic.png"));
        let rendered=page_images(&source,"refs",false,false,Some(&sources)).unwrap();
        assert!(rendered.fragment.contains("href=\"https://example.invalid/\""),"{}",rendered.fragment);
        assert!(rendered.fragment.contains("data-md-src=\"pic.png\""),"{}",rendered.fragment);
        assert_eq!(rendered.fragment.matches(visible_blank_lines::CLASS).count(),1);
        assert_eq!(rendered.configuration["blocks"].as_array().unwrap().iter().map(|block|block["source"].as_str().unwrap()).collect::<String>(),source);
    }
    #[test]
    fn cr_parser_view_preserves_every_rich_source_block_and_global_references() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("pic.png"), include_bytes!("../tests/fixtures/pixel-1.png")).unwrap();
        let lf = "雪🙂\n\n```md\n# code\n![fake](missing.png)\n==literal==\n```\n\n~~~text\nsecond\n~~~\n\n```\nthird\n```\n\n$$\na+b\n  \n# formula heading\n![math](missing.png)\n$$\n\n  \n# Real\n\n==Marked== [link][r] ![picture][p]\n\n[r]: https://example.invalid/\n[p]: pic.png\n";
        for eol in ["\n", "\r\n", "\r"] {
            let source = lf.replace('\n', eol);
            let sources = images::Sources::collect(&source, Some(&dir.path().join("source.md")), "cr-map").unwrap();
            assert_eq!(sources.0.len(),1);
            let page = page_images(&source, "cr-map", false, false, Some(&sources)).unwrap();
            let reconstructed = page.configuration["blocks"].as_array().unwrap().iter().map(|b|b["source"].as_str().unwrap()).collect::<String>();
            assert_eq!(reconstructed,source);
            assert!(page.fragment.contains("data-md-src=\"pic.png\""));
            assert!(page.fragment.contains("href=\"https://example.invalid/\""));
            assert!(page.fragment.contains("<mark>Marked</mark>"));
            assert_eq!(page.fragment.matches(visible_blank_lines::CLASS).count(),1);
            let opaque = page.configuration["opaqueSources"].as_object().unwrap().values().map(|v|v.as_str().unwrap()).collect::<Vec<_>>();
            assert_eq!(page.fragment.matches("<pre><code").count(), 3);
            assert!(page.fragment.contains("==literal=="));
            assert!(!page.fragment.contains("<mark>literal</mark>"));
            assert!(!opaque.iter().any(|text|text.contains("==literal==")));
            assert!(opaque.iter().any(|text|text.contains("# formula heading")));
            assert!(page.html.contains("katex.js"));
            assert!(page.fragment.contains("data-tex=\""));
        }
    }
    #[test]
    fn visible_blank_global_reference_destinations() { check_global_reference_destinations(""); }
    #[test]
    fn visible_blank_marked_global_reference_destinations() { check_global_reference_destinations("==Marked== "); }
    #[test]
    fn visible_blank_rich_math_gap_matches_mac_blank_assertions() {
        let source="| A | B |\n| - | - |\n| 1 | 2 |\n  \n![Bild](bild.png)\n  \n$$\nx + y\n  \nz\n$$\n  \nEnde";
        let rendered = page(source, "math-gap", false, false).unwrap();
        assert_eq!(
            rendered
                .fragment
                .matches(visible_blank_lines::CLASS)
                .count(),
            3
        );
        assert_eq!(
            rendered.configuration["blocks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|b| b["source"].as_str().unwrap())
                .collect::<String>(),
            source
        );
    }
    #[test]
    fn visible_blank_gap_keeps_existing_block_limit() {
        assert!(page(&"  \n".repeat(MAX_BLOCKS + 1), "limit", false, false).is_err());
    }
    #[test]
    fn visible_blank_lines_retain_source_blocks_and_container_order() {
        for source in [
            "  \r\n雪\r\n  \r\n- Eins\r\n  \r\n- Zwei\r\n  \r\n  \r\nOmega\r\n  ",
            "-\n-\n  \n  \nText",
            "> Eins\n>   \n> Zwei",
        ] {
            let rendered = page(source, "blank-test", false, false).unwrap();
            let restored = rendered.configuration["blocks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|b| b["source"].as_str().unwrap())
                .collect::<String>();
            assert_eq!(restored, source);
            if source.starts_with("  \r\n") {
                assert!(rendered.fragment.contains("data-srcline=\"5\""));
            }
            let mut expected = String::new();
            html::push_html(
                &mut expected,
                visible_blank_lines::events(source, Options::ENABLE_MATH)
                    .unwrap()
                    .into_iter()
                    .map(|e| e.0),
            );
            assert_eq!(
                rendered
                    .fragment
                    .matches(visible_blank_lines::CLASS)
                    .count(),
                expected.matches(visible_blank_lines::CLASS).count()
            );
            assert_eq!(
                rendered.fragment.matches("<ul").count(),
                expected.matches("<ul").count()
            );
            if source.starts_with("-\n") {
                assert!(
                    rendered.fragment.find("</ul>").unwrap()
                        < rendered.fragment.find(visible_blank_lines::CLASS).unwrap()
                );
            }
            assert!(!rendered.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .any(|v| v.as_str().unwrap().contains(visible_blank_lines::CLASS)));
        }
    }
    #[test]
    fn blocks_retain_exact_source_and_protect_unknown_syntax() {
        let source="# Title\r\n\r\nA&nbsp;B 😀 with [link](https://example.invalid).\r\n\r\n- one\n- two\n\n| A | B |\n|---|---|\n|雪|Ω|\n\n```mermaid\ngraph LR; A-->B\n```\n\n<script>bad()</script>\n\n[id]: /ref\n";
        let rendered = page(source, "test", false, false).unwrap();
        let restored = rendered.configuration["blocks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["source"].as_str().unwrap())
            .collect::<String>();
        assert_eq!(restored, source);
        assert!(!rendered.html.contains("<script>bad()"));
        assert!(rendered.html.contains("data-md-opaque"));
        assert!(rendered.html.contains("data-md-table=\"gfm\""));
        assert!(rendered
            .html
            .contains("<a href=\"https://example.invalid\""));
        assert!(rendered.configuration["opaqueSources"]
            .as_object()
            .unwrap()
            .values()
            .any(|v| v.as_str().unwrap().contains("```mermaid")));
    }
    #[test]
    fn clipboard_fragments_have_fresh_atom_names_and_no_foreign_block_ids() {
        let first=page("==Marked== and **Bold&nbsp;**\n\n<script>first()</script>\n","first",false,false).unwrap();
        let second=page("Other\n\n<script>second()</script>\n","second",false,false).unwrap();
        assert!(first.html.contains("<mark>Marked</mark>"));
        assert!(first.fragment.contains("<mark>Marked</mark>"));
        assert!(!first.fragment.contains("data-md-block"));
        let first_keys=first.configuration["opaqueSources"].as_object().unwrap();
        let second_keys=second.configuration["opaqueSources"].as_object().unwrap();
        assert!(first_keys.keys().all(|key|!second_keys.contains_key(key)));
    }
    #[test]
    fn mirrored_edits_use_minimal_unicode_boundaries() {
        for (old, new, prefix, suffix) in [
            ("a😀b", "a😁b", 1, 1),
            ("ä", "å", 0, 0),
            ("aXYZz", "aQz", 1, 1),
            ("α", "αβ", 2, 0),
            ("same", "same", 4, 0),
        ] {
            assert_eq!(changed_range(old, new), (prefix, suffix));
            let mut rebuilt = old[..prefix].to_owned();
            rebuilt.push_str(&new[prefix..new.len() - suffix]);
            rebuilt.push_str(&old[old.len() - suffix..]);
            assert_eq!(rebuilt, new);
        }
    }
    #[test]
    fn inline_html_is_a_small_attribute_free_allowlist() {
        for safe in ["<strong>", "</em>", "<br />", "<mark>"] {
            assert!(safe_inline(safe));
        }
        for unsafe_html in [
            "<img src=x onerror=alert(1)>",
            "<strong onclick=x>",
            "<script>",
            "<iframe>",
        ] {
            assert!(!safe_inline(unsafe_html));
        }
        assert!(!safe_link("javascript:alert(1)"));
        assert!(page(&"a".repeat(MAX_BYTES + 1), "s", false, false).is_err());
        assert!(page("a\0b", "s", false, false).is_err());
    }
}

pub(super) fn raster_extension(path: &std::path::Path) -> Option<&'static str> { images::extension(path) }

pub(super) mod save_as;

pub(super) fn relocation_safe_inline(raw:&str)->bool { safe_inline(raw) }

#[cfg(test)] mod autolink_tests;
#[cfg(test)]
mod latency_probe {
    use super::*;
    #[test]
    #[ignore]
    fn measure_rich_page_latency() {
        for (name,source) in [
            ("small-plain","# Title\n\nA paragraph with Unicode 雪🙂.\n\nTail\n".to_owned()),
            ("plain-100k","ordinary text 雪🙂 ".repeat(5000)),
            ("plain-1m","ordinary text 雪🙂 ".repeat(50000)),
            ("small-links","https://example.com/ www.example.com a@example.com\n\nTail\n".to_owned()),
            ("small-math","Before $x$ after\n\nhttps://example.com/$x$\n\nTail\n".to_owned()),
        ] {
            let _=page(&source,"warm",false,false).unwrap();let mut samples=Vec::new();
            for _ in 0..11{let start=std::time::Instant::now();std::hint::black_box(page(&source,"measure",false,false).unwrap());samples.push(start.elapsed().as_micros());}
            samples.sort_unstable();println!("LATENCY {name} bytes={} median_us={} max_us={}",source.len(),samples[5],samples[10]);
        }
    }
}
