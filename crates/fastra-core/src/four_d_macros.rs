//! Reine 4D-Textmakros; kein Methodenaufruf wird als Text ausgeführt.
use crate::Cancellation;
use roxmltree::{Document, Node, ParsingOptions};
enum NodeEdge<'a, 'input> {
    Open(Node<'a, 'input>),
    Close(Node<'a, 'input>),
}
use serde::Serialize;
use std::{collections::HashSet, ffi::CString, ops::Range};
use unicode_normalization::UnicodeNormalization;
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Xml(String),
    Limit(&'static str),
    Cancelled,
    Unsupported(String),
    InvalidRange,
    Locale,
}
pub type Result<T> = std::result::Result<T, Error>;
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub source_bytes: usize,
    pub macro_count: usize,
    pub text_utf16: usize,
    pub parts: usize,
    pub output_bytes: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            source_bytes: 8 * 1024 * 1024,
            macro_count: 4096,
            text_utf16: 4 * 1024 * 1024,
            parts: 131072,
            output_bytes: 8 * 1024 * 1024,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Part {
    Literal(String),
    Caret,
    Selection,
    FullText,
    MethodName,
    UserOS,
    Clipboard,
    Date(i64),
    Time(i64),
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Macro {
    pub id: String,
    pub display_name: String,
    pub shortcut: Option<String>,
    pub parts: Vec<Part>,
    pub method_call: Option<String>,
    #[serde(skip)]
    pub method_count: usize,
    pub separator: bool,
    pub source_label: String,
    pub unknown_placeholder: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Capability {
    NativeText,
    Runtime(&'static str),
    Unsupported(String),
}
fn check(cancel: &Cancellation) -> Result<()> {
    cancel.check().map_err(|_| Error::Cancelled)
}
fn units(s: &str) -> usize {
    s.encode_utf16().count()
}
fn append(parts: &mut Vec<Part>, part: Part, count: &mut usize, limits: Limits) -> Result<()> {
    if *count >= limits.parts {
        return Err(Error::Limit("macro parts"));
    }
    *count += 1;
    parts.push(part);
    Ok(())
}
fn flush(
    literal: &mut String,
    parts: &mut Vec<Part>,
    count: &mut usize,
    limits: Limits,
) -> Result<()> {
    if !literal.is_empty() {
        append(parts, Part::Literal(std::mem::take(literal)), count, limits)?;
    }
    Ok(())
}
pub fn split_name(raw: &str) -> (String, Option<String>) {
    let Ok(chars) = crate::icu::graphemes(raw) else {
        return (raw.into(), None);
    };
    if chars.len() < 3
        || chars[chars.len() - 3] != " "
        || chars[chars.len() - 2] != "/"
        || chars.last().unwrap().chars().all(char::is_whitespace)
    {
        return (raw.into(), None);
    }
    let key = chars[chars.len() - 1];
    let lower = key.to_lowercase();
    let key = if crate::icu::graphemes(&lower).is_ok_and(|g| g.len() == 1) {
        lower
    } else {
        key.into()
    };
    (
        chars[..chars.len() - 3].concat().trim_end().into(),
        Some(key),
    )
}
pub fn resolve_shortcuts(macros: &mut [Macro], reserved: &HashSet<String>) {
    let mut claimed = HashSet::new();
    for m in macros {
        if m.shortcut
            .as_ref()
            .is_some_and(|k| reserved.contains(k) || !claimed.insert(k.clone()))
        {
            m.shortcut = None;
        }
    }
}
/// XML-Bytes werden ausschließlich anhand BOM, XML-Signatur oder deklarierter Kodierung gelesen.
/// Der allgemeine Dateicodec darf hier keine undeutlichen Bytes als Latin-1 erraten.
pub fn parse_bytes(
    bytes: &[u8],
    source_label: &str,
    source_key: &str,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Vec<Macro>> {
    use crate::encoding::{self, Encoding};
    check(cancel)?;
    if bytes.len() > limits.source_bytes {
        return Err(Error::Limit("XML bytes"));
    }
    let (_, bom) = encoding::detect_bom(bytes);
    let detected = bom.or_else(|| {
        if bytes.starts_with(&[0, b'<', 0, b'?']) {
            Some(Encoding::Utf16Be)
        } else if bytes.starts_with(&[b'<', 0, b'?', 0]) {
            Some(Encoding::Utf16Le)
        } else if bytes.starts_with(&[0, 0, 0, b'<']) {
            Some(Encoding::Utf32Be)
        } else if bytes.starts_with(&[b'<', 0, 0, 0]) {
            Some(Encoding::Utf32Le)
        } else {
            None
        }
    });
    let preliminary = if let Some(enc) = detected {
        encoding::decode(bytes, Some(enc))
            .map_err(|e| Error::Xml(format!("XML encoding: {e}")))?
            .text()
            .to_owned()
    } else {
        let end = bytes
            .windows(2)
            .take(1024)
            .position(|pair| pair == b"?>")
            .map_or(0, |n| n + 2);
        std::str::from_utf8(&bytes[..end])
            .map_err(|_| Error::Xml("Invalid XML declaration encoding".into()))?
            .to_owned()
    };
    let declaration = preliminary
        .strip_prefix("<?xml")
        .and_then(|s| s.split_once("?>").map(|(s, _)| s));
    let named = declaration
        .and_then(|s| s.split_once("encoding").map(|(_, s)| s.trim_start()))
        .and_then(|s| s.strip_prefix('='))
        .map(str::trim_start)
        .and_then(|s| {
            let quote = s.chars().next()?;
            if !matches!(quote, '\'' | '"') {
                return None;
            }
            s[1..]
                .split_once(quote)
                .map(|(name, _)| name.to_lowercase())
        });
    let declared = match named.as_deref() {
        None => None,
        Some("utf-8" | "utf8") => Some(Encoding::Utf8),
        Some("utf-16") => Some(
            detected
                .filter(|e| matches!(e, Encoding::Utf16Le | Encoding::Utf16Be))
                .ok_or_else(|| Error::Xml("UTF-16 XML needs byte order".into()))?,
        ),
        Some("utf-16le") => Some(Encoding::Utf16Le),
        Some("utf-16be") => Some(Encoding::Utf16Be),
        Some("utf-32") => Some(
            detected
                .filter(|e| matches!(e, Encoding::Utf32Le | Encoding::Utf32Be))
                .ok_or_else(|| Error::Xml("UTF-32 XML needs byte order".into()))?,
        ),
        Some("utf-32le") => Some(Encoding::Utf32Le),
        Some("utf-32be") => Some(Encoding::Utf32Be),
        Some("iso-8859-1" | "latin1") => Some(Encoding::Latin1),
        Some("windows-1252") => Some(Encoding::Windows1252),
        Some("macintosh" | "macroman") => Some(Encoding::MacRoman),
        Some(name) => return Err(Error::Xml(format!("Unsupported XML encoding: {name}"))),
    };
    if bom.is_some() && declared.is_some() && bom != declared {
        return Err(Error::Xml(
            "Conflicting XML byte order and declaration".into(),
        ));
    }
    let decoded = encoding::decode(bytes, Some(declared.or(detected).unwrap_or(Encoding::Utf8)))
        .map_err(|e| Error::Xml(format!("XML encoding: {e}")))?;
    parse(decoded.text(), source_label, source_key, limits, cancel)
}
fn lexical_name<'a>(source: &'a str, node: Node<'_, '_>) -> Result<&'a str> {
    let raw = source
        .get(node.range().start..)
        .and_then(|s| s.strip_prefix('<'))
        .ok_or_else(|| Error::Xml("Unbound XML element".into()))?;
    raw.split(|c: char| c.is_whitespace() || matches!(c, '/' | '>'))
        .next()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::Xml("Missing XML element name".into()))
}
pub fn parse(
    source: &str,
    source_label: &str,
    source_key: &str,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Vec<Macro>> {
    check(cancel)?;
    if source.len() > limits.source_bytes {
        return Err(Error::Limit("XML bytes"));
    }
    let options = ParsingOptions {
        allow_dtd: true,
        nodes_limit: 400000,
        entity_resolver: None,
    };
    let doc =
        Document::parse_with_options(source, options).map_err(|e| Error::Xml(e.to_string()))?;
    let mut macros = Vec::new();
    let mut current = None::<Macro>;
    let mut literal = String::new();
    let (mut depth, mut text_depth, mut method_depth) = (0, None, None);
    let (mut text_units, mut part_count) = (0usize, 0usize);
    let mut cursor = Some(NodeEdge::Open(doc.root()));
    while let Some(edge) = cursor {
        cursor = match &edge {
            NodeEdge::Open(n) => Some(n.first_child().map_or(NodeEdge::Close(*n), NodeEdge::Open)),
            NodeEdge::Close(n) => n
                .next_sibling()
                .map(NodeEdge::Open)
                .or_else(|| n.parent().map(NodeEdge::Close)),
        };
        check(cancel)?;
        match edge {
            NodeEdge::Open(node) => {
                depth += 1;
                if depth > 258 {
                    return Err(Error::Limit("XML nesting"));
                }
                if node.is_text() {
                    let text = node.text().unwrap_or("");
                    text_units = text_units
                        .checked_add(units(text))
                        .ok_or(Error::Limit("XML text"))?;
                    if text_units > limits.text_utf16 {
                        return Err(Error::Limit("XML text"));
                    }
                    if let Some(m) = current.as_mut() {
                        if method_depth.is_some() {
                            m.method_call.as_mut().unwrap().push_str(text);
                        } else if text_depth.is_some() {
                            literal.push_str(text);
                        }
                    }
                    continue;
                }
                if !node.is_element() {
                    continue;
                }
                let name = lexical_name(source, node)?;
                if name == "macro" {
                    if current.is_some() {
                        return Err(Error::Xml("Nested macro".into()));
                    }
                    if macros.len() >= limits.macro_count {
                        return Err(Error::Limit("macro count"));
                    }
                    let raw = node.attribute("name").unwrap_or("");
                    let separator = raw.trim() == "-";
                    let (display_name, shortcut) = if separator {
                        ("-".into(), None)
                    } else {
                        split_name(raw)
                    };
                    current = Some(Macro {
                        id: format!("{source_key}#{}", macros.len()),
                        display_name,
                        shortcut,
                        parts: Vec::new(),
                        method_call: None,
                        method_count: 0,
                        separator,
                        source_label: source_label.into(),
                        unknown_placeholder: None,
                    });
                    continue;
                }
                let Some(m) = current.as_mut() else {
                    continue;
                };
                if method_depth.is_some() {
                    if name == "method_name" {
                        text_units += 14;
                        if text_units > limits.text_utf16 {
                            return Err(Error::Limit("XML text"));
                        }
                        m.method_call.as_mut().unwrap().push_str("<method_name/>");
                    } else if m.unknown_placeholder.is_none() {
                        m.unknown_placeholder = Some(name.into());
                    }
                    continue;
                }
                if text_depth.is_none() {
                    if name == "text" {
                        text_depth = Some(depth);
                    }
                    continue;
                }
                if name == "method" {
                    m.method_count += 1;
                    method_depth = Some(depth);
                    m.method_call = Some(String::new());
                    continue;
                }
                let number = || {
                    node.attribute("format")
                        .map_or(0, |s| s.trim().parse().unwrap_or(-1))
                };
                let part = match name {
                    "caret" => Part::Caret,
                    "selection" => Part::Selection,
                    "text" => Part::FullText,
                    "method_name" => Part::MethodName,
                    "user_os" => Part::UserOS,
                    "clipboard" => Part::Clipboard,
                    "date" => Part::Date(number()),
                    "time" => Part::Time(number()),
                    _ => {
                        if m.unknown_placeholder.is_none() {
                            m.unknown_placeholder = Some(name.into());
                        }
                        continue;
                    }
                };
                flush(&mut literal, &mut m.parts, &mut part_count, limits)?;
                append(&mut m.parts, part, &mut part_count, limits)?;
            }
            NodeEdge::Close(node) => {
                if node.is_element() {
                    let name = lexical_name(source, node)?;
                    if method_depth == Some(depth) && name == "method" {
                        method_depth = None;
                    } else if text_depth == Some(depth) && name == "text" {
                        text_depth = None;
                    } else if name == "macro" {
                        if let Some(mut m) = current.take() {
                            flush(&mut literal, &mut m.parts, &mut part_count, limits)?;
                            macros.push(m);
                        }
                        text_depth = None;
                        method_depth = None;
                    }
                }
                depth -= 1;
            }
        }
    }
    Ok(macros)
}
pub fn normalized_method_name(file_name: &str) -> String {
    let name = if file_name.to_lowercase().ends_with(".4dm") {
        &file_name[..file_name.len() - 4]
    } else {
        file_name
    };
    name.nfc().collect()
}
pub fn method_call(call: &str) -> Option<(String, Vec<String>)> {
    let call = call.trim();
    if call.is_empty() {
        return None;
    }
    let mut quoted = false;
    let mut escaped = false;
    let mut open = None;
    for (i, c) in call.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && c == '\\' {
            escaped = true;
            continue;
        }
        if c == '"' {
            quoted = !quoted;
        } else if !quoted && c == '(' {
            open = Some(i);
            break;
        }
    }
    let Some(open) = open else {
        return Some((call.into(), vec![]));
    };
    let name = call[..open].trim();
    if name.is_empty() {
        return None;
    }
    let mut depth = 0;
    let mut start = open + 1;
    let mut args = Vec::new();
    quoted = false;
    escaped = false;
    for (i, c) in call[open..].char_indices().map(|(i, c)| (i + open, c)) {
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && c == '\\' {
            escaped = true;
            continue;
        }
        if c == '"' {
            quoted = !quoted;
            continue;
        }
        if quoted {
            continue;
        }
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    if !call[i + 1..].trim().is_empty() {
                        return None;
                    }
                    let last = call[start..i].trim();
                    if !args.is_empty() || !last.is_empty() {
                        args.push(last.into());
                    }
                    return Some((name.into(), args));
                }
            }
            ']' | '}' => depth -= 1,
            ';' if depth == 1 => {
                args.push(call[start..i].trim().into());
                start = i + 1;
            }
            _ => {}
        }
    }
    None
}
fn runtime_variant(args: &[String]) -> Option<&'static str> {
    if !args
        .first()
        .is_some_and(|a| matches!(a.trim(), "<method_name/>" | "\"<method_name/>\""))
    {
        return None;
    }
    let boolean = |i: usize| args.get(i).map(|a| a.trim().to_lowercase());
    match args.len() {
        1 => Some("komplettieren"),
        2 if boolean(1).as_deref() == Some("false") => Some("komplettieren"),
        3 if boolean(1).as_deref() == Some("false") && args[2].trim() == "\"\"" => {
            Some("komplettieren")
        }
        4 | 5 if boolean(1).as_deref() == Some("false") && args[2].trim() == "\"\"" => {
            match (boolean(3).as_deref(), boolean(4).as_deref()) {
                (Some("false"), None) => Some("komplettieren"),
                (Some("true"), None) => Some("komplettieren-ohne-nv"),
                (Some("false"), Some("false")) => Some("komplettieren-ohne-var"),
                (Some("true"), Some("false")) => Some("komplettieren-ohne-nv-var"),
                _ => None,
            }
        }
        _ => None,
    }
}
pub fn capability(m: &Macro) -> Capability {
    if m.separator {
        return Capability::Unsupported("separator".into());
    }
    if let Some(p) = &m.unknown_placeholder {
        return Capability::Unsupported(format!("unknown-placeholder:{p}"));
    }
    // Mehrere Methodenaufrufe dürfen nicht durch den letzten (möglicherweise leeren) verdeckt werden.
    if m.method_count > 1 {
        return Capability::Unsupported("multiple-method-calls".into());
    }
    if let Some(call) = m.method_call.as_deref().filter(|s| !s.trim().is_empty()) {
        if let Some((name, args)) = method_call(call) {
            if name.eq_ignore_ascii_case("MAO_MethodeKomplettierenNeu") {
                if let Some(variant) = runtime_variant(&args) {
                    return Capability::Runtime(variant);
                }
                return Capability::Unsupported("runtime-arguments".into());
            }
            return Capability::Unsupported(format!("method:{name}"));
        }
        return Capability::Unsupported("invalid-method-call".into());
    }
    for part in &m.parts {
        match part {
            Part::Date(n) if !(0..=8).contains(n) => {
                return Capability::Unsupported(format!("date-format:{n}"))
            }
            Part::Time(n) if !(0..=6).contains(n) => {
                return Capability::Unsupported(format!("time-format:{n}"))
            }
            _ => {}
        }
    }
    if !m
        .parts
        .iter()
        .any(|p| !matches!(p,Part::Literal(s)if s.trim().is_empty()))
    {
        return Capability::Unsupported("display-only".into());
    }
    if m.parts.contains(&Part::Clipboard) {
        return Capability::Unsupported("clipboard".into());
    }
    Capability::NativeText
}
pub struct Context<'a> {
    pub full_text: &'a str,
    pub selection: Range<usize>,
    pub method_name: &'a str,
    pub user_os: &'a str,
    pub dates: &'a [String; 9],
    pub times: &'a [String; 7],
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Insertion {
    pub text: String,
    pub caret_utf16: Option<usize>,
}
pub fn render(
    m: &Macro,
    context: &Context<'_>,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Insertion> {
    if capability(m) != Capability::NativeText {
        return Err(Error::Unsupported(format!("{:?}", capability(m))));
    }
    let selection = context
        .full_text
        .get(context.selection.clone())
        .ok_or(Error::InvalidRange)?;
    let mut text = String::new();
    let mut caret = None;
    for part in &m.parts {
        check(cancel)?;
        let value = match part {
            Part::Literal(s) => s,
            Part::Selection => selection,
            Part::FullText => context.full_text,
            Part::MethodName => context.method_name,
            Part::UserOS => context.user_os,
            Part::Date(n) => &context.dates[*n as usize],
            Part::Time(n) => &context.times[*n as usize],
            Part::Caret => {
                if caret.is_none() {
                    caret = Some(units(&text));
                }
                continue;
            }
            Part::Clipboard => return Err(Error::Unsupported("clipboard".into())),
        };
        if text.len().saturating_add(value.len()) > limits.output_bytes {
            return Err(Error::Limit("expanded macro bytes"));
        }
        text.push_str(value);
    }
    Ok(Insertion {
        text,
        caret_utf16: caret,
    })
}
unsafe extern "C" {
    fn fastra_macro_datetime(
        millis: f64,
        format: i32,
        time: i32,
        locale: *const std::ffi::c_char,
        zone: *const u16,
        zone_len: i32,
        out: *mut u16,
        capacity: i32,
        status: *mut i32,
    ) -> i32;
}
pub fn date_time(millis: f64, locale: &str, zone: &str, time: bool, format: u8) -> Result<String> {
    if !millis.is_finite()
        || (!time && format > 8)
        || (time && format > 6)
        || locale.len() > 256
        || zone.len() > 256
    {
        return Err(Error::Locale);
    }
    let locale = CString::new(locale).map_err(|_| Error::Locale)?;
    let zone: Vec<u16> = zone.encode_utf16().collect();
    let mut output = vec![0u16; 4096];
    let mut status = 0;
    let count = unsafe {
        fastra_macro_datetime(
            millis,
            format.into(),
            time.into(),
            locale.as_ptr(),
            zone.as_ptr(),
            zone.len() as i32,
            output.as_mut_ptr(),
            output.len() as i32,
            &mut status,
        )
    };
    if status > 0 || count < 0 || count as usize > output.len() {
        return Err(Error::Locale);
    }
    String::from_utf16(&output[..count as usize]).map_err(|_| Error::Locale)
}
#[cfg(test)]
mod tests;
