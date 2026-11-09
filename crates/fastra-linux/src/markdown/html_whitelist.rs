//! Enge Mac-Positivliste: Fragmente vollständig prüfen und kanonisch neu erzeugen.
use super::*;
use unicode_segmentation::UnicodeSegmentation;

const ALLOWED: &[&str] = &[
    "p",
    "div",
    "span",
    "br",
    "hr",
    "center",
    "blockquote",
    "pre",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "b",
    "strong",
    "i",
    "em",
    "u",
    "s",
    "strike",
    "del",
    "ins",
    "mark",
    "small",
    "sub",
    "sup",
    "code",
    "kbd",
    "samp",
    "var",
    "q",
    "cite",
    "abbr",
    "dfn",
    "ul",
    "ol",
    "li",
    "dl",
    "dt",
    "dd",
    "table",
    "thead",
    "tbody",
    "tfoot",
    "tr",
    "th",
    "td",
    "caption",
    "colgroup",
    "col",
    "a",
    "img",
    "details",
    "summary",
];
fn void(name: &str) -> bool {
    matches!(name, "br" | "hr" | "img" | "col" | "wbr")
}
fn allowed_attribute(name: &str, attr: &str) -> bool {
    matches!(attr, "align" | "title" | "dir" | "lang")
        || match name {
            "a" => attr == "href",
            "img" => matches!(attr, "src" | "alt" | "width" | "height"),
            "table" => attr == "width",
            "td" => matches!(attr, "colspan" | "rowspan" | "valign" | "width"),
            "th" => matches!(attr, "colspan" | "rowspan" | "valign" | "width" | "scope"),
            "col" => matches!(attr, "span" | "width"),
            "colgroup" => attr == "span",
            "ol" => matches!(attr, "start" | "type" | "reversed"),
            "details" => attr == "open",
            "blockquote" | "q" => attr == "cite",
            _ => false,
        }
}
fn horizontal_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn safe_link(value: &str) -> bool {
    let value = value.trim_matches(horizontal_whitespace);
    if value.is_empty() || value.starts_with("//") {
        return false;
    }
    let Some((scheme, _)) = value.split_once(':') else {
        return true;
    };
    scheme.contains(['/', '?', '#'])
        || matches!(scheme.to_lowercase().as_str(), "http" | "https" | "mailto")
}
fn digits(value: &str, max: usize, percent: bool) -> bool {
    let value = if percent {
        value.strip_suffix('%').unwrap_or(value)
    } else {
        value
    };
    !value.is_empty() && value.len() <= max && value.bytes().all(|b| b.is_ascii_digit())
}
fn valid_attribute(attr: &str, value: &str) -> bool {
    if value.chars().any(|c| c < '\u{20}' || c == '\u{7f}') {
        return false;
    }
    match attr {
        "align" => matches!(
            value.to_lowercase().as_str(),
            "left" | "center" | "right" | "justify"
        ),
        "valign" => matches!(
            value.to_lowercase().as_str(),
            "top" | "middle" | "bottom" | "baseline"
        ),
        "dir" => matches!(value.to_lowercase().as_str(), "ltr" | "rtl" | "auto"),
        "scope" => matches!(
            value.to_lowercase().as_str(),
            "row" | "col" | "rowgroup" | "colgroup"
        ),
        "type" => matches!(value, "1" | "a" | "A" | "i" | "I"),
        "width" | "height" => digits(value, 5, true),
        "colspan" | "rowspan" | "span" | "start" => digits(value, 4, false),
        "href" | "cite" => safe_link(value),
        "src" => !value.is_empty(),
        "alt" | "title" | "lang" => value.graphemes(true).take(513).count() <= 512,
        _ => false,
    }
}
fn entity_len(value: &str, decimal_limit: usize, hex_limit: usize) -> Option<usize> {
    let end = value.as_bytes().iter().take(35).position(|b| *b == b';')?;
    let entity = &value[1..end];
    let valid = if let Some(hex) = entity
        .strip_prefix("#x")
        .or_else(|| entity.strip_prefix("#X"))
    {
        !hex.is_empty() && hex.len() <= hex_limit && hex.bytes().all(|b| b.is_ascii_hexdigit())
    } else if let Some(decimal) = entity.strip_prefix('#') {
        digits(decimal, decimal_limit, false)
    } else {
        (2..=32).contains(&entity.len())
            && entity.as_bytes()[0].is_ascii_alphabetic()
            && entity.bytes().all(|b| b.is_ascii_alphanumeric())
    };
    valid.then_some(end + 1)
}
pub(super) fn decode(value: &str, cancel: &Cancellation) -> Result<String, RenderError> {
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        cancel.check().map_err(|_| RenderError::Cancelled)?;
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        if let Some(len) = entity_len(rest, 8, 8) {
            // Jede Referenz wird einmal aufgelöst; benannte bleiben beim vorhandenen Parser.
            // Der dekodierte Wert wird niemals erneut als Markup geparst.
            if let Some(number) = rest[..len].strip_prefix("&#") {
                // Gepinntes Mac-Houdini erlaubt in Attributen in beiden Basen
                // bis acht Ziffern; seine Text-Escaperegel bleibt davon getrennt.
                let number = &number[..number.len() - 1];
                let (number, radix) = number
                    .strip_prefix('x')
                    .or_else(|| number.strip_prefix('X'))
                    .map_or((number, 10), |hex| (hex, 16));
                let scalar = u32::from_str_radix(number, radix)
                    .ok()
                    .and_then(char::from_u32)
                    .filter(|scalar| *scalar != '\0')
                    .unwrap_or('\u{fffd}');
                out.push(scalar);
            } else {
                for event in pulldown_cmark::Parser::new(&rest[..len]) {
                    if let Event::Text(text) = event {
                        out.push_str(&text);
                    }
                }
            }
            rest = &rest[len..];
        } else {
            out.push('&');
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    Ok(out)
}
fn text(value: &str) -> Option<String> {
    if value.contains('>') {
        return None;
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        if let Some(len) = entity_len(rest, 7, 6) {
            out.push_str(&rest[..len]);
            rest = &rest[len..];
        } else {
            out.push_str("&amp;");
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    Some(out)
}
#[derive(Debug)]
enum Piece {
    Text(String),
    Close(String),
    Open(String, Vec<(String, Option<String>)>),
}
fn start(raw: &str, cancel: &Cancellation) -> Result<Option<Piece>, RenderError> {
    let self_closing = raw.ends_with('/');
    let mut rest = raw
        .strip_suffix('/')
        .unwrap_or(raw)
        .trim_start_matches(char::is_whitespace);
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let name = rest[..end].to_lowercase();
    rest = &rest[end..];
    if !ALLOWED.contains(&name.as_str()) || (self_closing && !void(&name)) {
        return Ok(None);
    }
    let mut attrs: Vec<(String, Option<String>)> = Vec::new();
    loop {
        cancel.check().map_err(|_| RenderError::Cancelled)?;
        rest = rest.trim_start_matches(char::is_whitespace);
        if rest.is_empty() {
            break;
        }
        let end = rest
            .find(|c: char| c.is_whitespace() || c == '=')
            .unwrap_or(rest.len());
        let attr = rest[..end].to_lowercase();
        rest = &rest[end..];
        if attr.is_empty()
            || !attr.as_bytes()[0].is_ascii_lowercase()
            || !attr
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            || attr.starts_with("on")
            || attrs.iter().any(|(seen, _)| seen == &attr)
            || !allowed_attribute(&name, &attr)
        {
            return Ok(None);
        }
        rest = rest.trim_start_matches(char::is_whitespace);
        if let Some(after) = rest.strip_prefix('=') {
            rest = after.trim_start_matches(char::is_whitespace);
            let Some(quote) = rest.chars().next().filter(|c| matches!(c, '\'' | '"')) else {
                return Ok(None);
            };
            rest = &rest[1..];
            let Some(end) = rest.find(quote) else {
                return Ok(None);
            };
            let value = decode(&rest[..end], cancel)?;
            rest = &rest[end + 1..];
            if !valid_attribute(&attr, &value) {
                return Ok(None);
            }
            attrs.push((attr, Some(value)));
        } else {
            if !matches!(attr.as_str(), "open" | "reversed") {
                return Ok(None);
            }
            attrs.push((attr, None));
        }
    }
    Ok(Some(Piece::Open(name, attrs)))
}
#[derive(Default)]
pub(super) struct Sanitizer {
    stack: Vec<String>,
    fragments: Vec<String>,
}
impl Sanitizer {
    pub(super) fn sanitize(
        &mut self,
        raw: &str,
        cancel: &Cancellation,
        mut image: impl FnMut(&str) -> Result<String, RenderError>,
    ) -> Result<Option<String>, RenderError> {
        let mut stack = self.stack.clone();
        let mut pieces = Vec::new();
        let mut rest = raw;
        while !rest.is_empty() {
            cancel.check().map_err(|_| RenderError::Cancelled)?;
            let Some(at) = rest.find('<') else {
                let Some(t) = text(rest) else {
                    return Ok(None);
                };
                pieces.push(Piece::Text(t));
                break;
            };
            if at > 0 {
                let Some(t) = text(&rest[..at]) else {
                    return Ok(None);
                };
                pieces.push(Piece::Text(t));
            }
            rest = &rest[at..];
            if let Some(comment) = rest.strip_prefix("<!--") {
                let Some(end) = comment.find("-->") else {
                    return Ok(None);
                };
                if comment[..end].contains("--") {
                    return Ok(None);
                }
                rest = &comment[end + 3..];
                continue;
            }
            if rest.starts_with("<!") || rest.starts_with("<?") {
                return Ok(None);
            }
            let mut quote = None;
            let mut close = None;
            for (at, c) in rest.char_indices().skip(1) {
                if let Some(active) = quote {
                    if c == active {
                        quote = None;
                    }
                } else if matches!(c, '\'' | '"') {
                    quote = Some(c);
                } else if c == '>' {
                    close = Some(at);
                    break;
                }
            }
            let Some(end) = close else {
                return Ok(None);
            };
            let raw = &rest[1..end];
            rest = &rest[end + 1..];
            if raw.contains('<') {
                return Ok(None);
            }
            if let Some(close) = raw.strip_prefix('/') {
                let close = close.trim_matches(horizontal_whitespace).to_lowercase();
                if stack.last() != Some(&close) {
                    return Ok(None);
                }
                stack.pop();
                pieces.push(Piece::Close(close));
            } else {
                let Some(piece) = start(raw, cancel)? else {
                    return Ok(None);
                };
                if let Piece::Open(name, _) = &piece {
                    if !void(name) {
                        stack.push(name.clone());
                        if stack.len() > 64 {
                            return Ok(None);
                        }
                    }
                }
                pieces.push(piece);
            }
        }
        // Erst nach erfolgreicher Prüfung des ganzen Fragments werden lokale Bilder geladen.
        let mut out = String::new();
        for piece in pieces {
            match piece {
                Piece::Text(t) => out.push_str(&t),
                Piece::Close(name) => out.push_str(&format!("</{name}>")),
                Piece::Open(name, attrs) => {
                    out.push('<');
                    out.push_str(&name);
                    for (attr, value) in attrs {
                        out.push(' ');
                        out.push_str(&attr);
                        if let Some(mut value) = value {
                            if name == "img" && attr == "src" {
                                value = image(&value)?;
                            }
                            out.push_str("=\"");
                            out.push_str(&escape(&value));
                            out.push('"');
                        }
                    }
                    out.push('>');
                }
            }
            if out.len() > 16 * 1024 * 1024 {
                return Err(RenderError::Limit);
            }
        }
        self.stack = stack;
        Ok(Some(out))
    }
    pub(super) fn store(&mut self, html: String) -> String {
        let token = format!("<!--fastra-sanitized-html-{}-->", self.fragments.len());
        self.fragments.push(html);
        token
    }
    pub(super) fn finish(mut self, fragment: String) -> Option<String> {
        if self.fragments.is_empty() {
            return Some(fragment);
        }
        // Rohes HTML bleibt bis nach SourceMap/Code-ID-Zuweisung getrennt. Die
        // Eingabe kann diese Kommentare nicht fälschen: Kommentare werden verworfen.
        let mut out = String::with_capacity(fragment.len());
        let mut rest = fragment.as_str();
        let count = self.fragments.len();
        let mut index = 0;
        while let Some(at) = rest.find("<!--fastra-sanitized-html-") {
            out.push_str(&rest[..at]);
            let token = format!("<!--fastra-sanitized-html-{index}-->");
            rest = rest[at..].strip_prefix(&token)?;
            out.push_str(self.fragments.get(index)?);
            index += 1;
            if out.len() > 16 * 1024 * 1024 {
                return None;
            }
        }
        if index != count {
            return None;
        }
        out.push_str(rest);
        while let Some(name) = self.stack.pop() {
            out.push_str(&format!("</{name}>"));
        }
        Some(out)
    }
}
