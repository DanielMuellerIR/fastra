//! Statische 4D-Quellnavigation; weder Compiler noch Laufzeit oder LSP-Ersatz.
use crate::{
    xpath::{SourceMap, Span},
    Cancellation,
};
use std::{ops::Range, sync::Arc};
use unicode_normalization::UnicodeNormalization;

pub(crate) mod folding;
mod lexical;
mod tokens;
pub use tokens::{learned_suffixes, retokenize, transform_tokens, TokenTransform};

pub fn method_key(name: &str) -> String {
    name.to_lowercase().nfc().collect()
}

pub const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_DEFINITIONS: usize = 10_000;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    Cancelled,
    Limit(&'static str),
    InvalidOffset,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;
fn check(cancel: &Cancellation) -> Result<()> {
    if cancel.check().is_err() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Function,
    Getter,
    Setter,
    Query,
    OrderBy,
    Constructor,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Definition {
    pub name: String,
    pub kind: Kind,
    pub span: Span,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parameter {
    pub name: String,
    pub type_name: Option<String>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Signature {
    pub parameters: Vec<Parameter>,
    pub returns: Option<Parameter>,
    pub header: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CallContext {
    pub method: String,
    pub active_parameter: usize,
    pub open_paren: Span,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mask {
    Code,
    Comment,
    String,
    Sql,
}
pub struct Analysis {
    source: Arc<str>,
    map: SourceMap,
    mask: Vec<Mask>,
    pub definitions: Vec<Definition>,
    pub signature: Signature,
}
fn map_error(error: crate::xpath::Error) -> Error {
    match error {
        crate::xpath::Error::Cancelled => Error::Cancelled,
        _ => Error::InvalidOffset,
    }
}
fn word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}
fn name_valid(s: &str) -> bool {
    s.chars()
        .next()
        .is_some_and(|c| c.is_alphabetic() || c == '_')
        && s.chars().all(word_char)
}
fn lines(source: &str) -> impl Iterator<Item = (usize, &str)> {
    let mut offset = 0;
    source.split_inclusive(['\r', '\n']).map(move |line| {
        let start = offset;
        offset += line.len();
        (start, line.trim_end_matches(['\r', '\n']))
    })
}
impl Analysis {
    pub fn build(source: &str, cancel: &Cancellation) -> Result<Self> {
        Self::build_bounded(source, MAX_SOURCE_BYTES, cancel)
    }
    pub fn outline(source: &str, cancel: &Cancellation) -> Result<Vec<Definition>> {
        Self::build_bounded(source, 10 * 1024 * 1024, cancel).map(|value| value.definitions)
    }
    fn build_bounded(source: &str, maximum: usize, cancel: &Cancellation) -> Result<Self> {
        check(cancel)?;
        if source.len() > maximum {
            return Err(Error::Limit("source bytes"));
        }
        let source: Arc<str> = Arc::from(source);
        let map = SourceMap::build_bounded(source.clone(), maximum, cancel).map_err(map_error)?;
        let mut mask = lexical::mask(&source, lexical::StringPolicy::Multiline, cancel)?;
        let mut sql = false;
        let mut definitions = Vec::new();
        for (offset, line) in lines(&source) {
            check(cancel)?;
            let trimmed = line.trim_start_matches([' ', '\t', '\u{feff}']);
            let start = offset + line.len() - trimmed.len();
            let code = |r: Range<usize>| mask[r].iter().all(|m| *m == Mask::Code);
            let lower = trimmed.to_lowercase();
            let normal = lower.split_whitespace().collect::<Vec<_>>().join(" ");
            if sql {
                if normal == "end sql" {
                    sql = false;
                }
                mask[offset..offset + line.len()].fill(Mask::Sql);
                continue;
            }
            if normal == "begin sql" && code(start..start + trimmed.len()) {
                sql = true;
                mask[offset..offset + line.len()].fill(Mask::Sql);
                continue;
            }
            let Some(paren) = trimmed.find('(') else {
                continue;
            };
            let head = &trimmed[..paren];
            let all_words: Vec<&str> = head.split_whitespace().collect();
            let mut words = all_words.as_slice();
            while words.first().is_some_and(|w| {
                ["exposed", "local", "server", "shared", "onhttpget"]
                    .contains(&w.to_lowercase().as_str())
            }) {
                words = &words[1..];
            }
            let mut constructor_words = all_words.as_slice();
            while constructor_words.first().is_some_and(|w| {
                ["shared", "singleton", "session"].contains(&w.to_lowercase().as_str())
            }) {
                constructor_words = &constructor_words[1..];
            }
            let definition = if constructor_words.len() == 2
                && constructor_words[0].eq_ignore_ascii_case("class")
                && constructor_words[1].eq_ignore_ascii_case("constructor")
            {
                Some(("Class constructor", Kind::Constructor))
            } else if words
                .first()
                .is_some_and(|w| w.eq_ignore_ascii_case("function"))
            {
                match words {
                    [_, name] if name_valid(name) => Some((*name, Kind::Function)),
                    [_, access, name] if name_valid(name) => {
                        let kind = match access.to_lowercase().as_str() {
                            "get" => Some(Kind::Getter),
                            "set" => Some(Kind::Setter),
                            "query" => Some(Kind::Query),
                            "orderby" => Some(Kind::OrderBy),
                            _ => None,
                        };
                        kind.map(|k| (*name, k))
                    }
                    _ => None,
                }
            } else {
                None
            };
            if let Some((name, kind)) = definition {
                if name.len() > 1024 {
                    return Err(Error::Limit("definition name bytes"));
                }
                if !code(start..start + paren + 1) {
                    continue;
                }
                if definitions.len() >= MAX_DEFINITIONS {
                    return Err(Error::Limit("definitions"));
                }
                definitions.push(Definition {
                    name: name.into(),
                    kind,
                    span: map.span(offset..start + paren).map_err(map_error)?,
                });
            }
        }
        let signature = parse_signature(&source, &mask, cancel)?;
        check(cancel)?;
        Ok(Self {
            source,
            map,
            mask,
            definitions,
            signature,
        })
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    /// Der Aufruf wird explizit für einen Cursor ausgewertet, nicht bei jedem Tastendruck neu geparst.
    pub fn call_context(
        &self,
        cursor: usize,
        cancel: &Cancellation,
    ) -> Result<Option<CallContext>> {
        check(cancel)?;
        if cursor > self.source.len() || !self.source.is_char_boundary(cursor) {
            return Err(Error::InvalidOffset);
        }
        if cursor > 0 && matches!(self.mask[cursor - 1], Mask::Comment | Mask::Sql) {
            return Ok(None);
        }
        let line_start = self.source[..cursor]
            .rfind(['\r', '\n'])
            .map_or(0, |i| i + 1);
        let mut stack: Vec<(usize, usize)> = Vec::new();
        for i in line_start..cursor {
            if i % 1024 == 0 {
                check(cancel)?;
            }
            if self.mask[i] != Mask::Code {
                continue;
            }
            match self.source.as_bytes()[i] {
                b'(' => {
                    if stack.len() >= 1024 {
                        return Err(Error::Limit("call nesting"));
                    }
                    stack.push((i, 0));
                }
                b')' => {
                    stack.pop();
                }
                b';' => {
                    if let Some((_, n)) = stack.last_mut() {
                        *n += 1;
                    }
                }
                _ => {}
            }
        }
        let Some((paren, active_parameter)) = stack.last().copied() else {
            return Ok(None);
        };
        let before = self.source[line_start..paren].trim_end_matches(' ');
        let end = before.len();
        let mut start = end;
        let mut chars = before.char_indices().rev().peekable();
        while let Some((i, c)) = chars.next() {
            if word_char(c) || (c == ' ' && chars.peek().is_some_and(|(_, c)| word_char(*c))) {
                start = i;
            } else {
                break;
            }
        }
        let method = before[start..end].trim();
        if method.len() > 1024 {
            return Err(Error::Limit("method name bytes"));
        }
        let boundary = before[..start].chars().next_back();
        const KEYWORDS: &[&str] = &[
            "if",
            "else",
            "end if",
            "case of",
            "end case",
            "for each",
            "end for each",
            "for",
            "end for",
            "while",
            "end while",
            "repeat",
            "until",
            "use",
            "end use",
            "begin sql",
            "end sql",
            "return",
            "break",
            "continue",
            "function",
            "class constructor",
            "class extends",
            "property",
            "var",
            "try",
            "catch",
            "end try",
            "throw",
            "true",
            "false",
            "null",
            "this",
            "super",
        ];
        if !method
            .chars()
            .next()
            .is_some_and(|c| c.is_alphabetic() || c == '_')
            || boundary.is_some_and(|c| matches!(c, '$' | '.' | ']' | '>'))
            || KEYWORDS.contains(&method.to_lowercase().as_str())
        {
            return Ok(None);
        }
        Ok(Some(CallContext {
            method: method.into(),
            active_parameter,
            open_paren: self.map.span(paren..paren + 1).map_err(map_error)?,
        }))
    }
}
fn parameter(raw: &str) -> Option<Parameter> {
    let (name, ty) = raw
        .split_once(':')
        .map_or((raw, None), |(a, b)| (a, Some(b.trim())));
    let name = name.trim();
    if !name.starts_with('$') || name.len() < 2 {
        return None;
    }
    Some(Parameter {
        name: name.into(),
        type_name: ty.filter(|t| !t.is_empty()).map(str::to_owned),
    })
}
fn parse_signature(source: &str, mask: &[Mask], cancel: &Cancellation) -> Result<Signature> {
    let mut result = Signature::default();
    let normalized = source
        .trim_start_matches('\u{feff}')
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let mut header = Vec::new();
    let mut block = false;
    for (i, line) in normalized.lines().enumerate() {
        check(cancel)?;
        let t = line.trim_start();
        if i == 0 && t.starts_with("//%attributes") {
            continue;
        }
        if block {
            header.push(line);
            if t.contains("*/") {
                block = false;
            }
            continue;
        }
        if t.starts_with("//") {
            header.push(line);
        } else if t.starts_with("/*") {
            header.push(line);
            block = !t.contains("*/");
        } else {
            break;
        }
    }
    result.header = header.join("\n");
    for (offset, line) in lines(source) {
        check(cancel)?;
        let trimmed = line.trim_start_matches([' ', '\t', '\u{feff}']);
        let start = offset + line.len() - trimmed.len();
        if mask.get(start) != Some(&Mask::Code) {
            continue;
        }
        if trimmed
            .get(..8)
            .is_some_and(|s| s.eq_ignore_ascii_case("#DECLARE"))
        {
            let rest = trimmed[8..].trim_start();
            if let Some(inner) = rest.strip_prefix('(').and_then(|r| r.rsplit_once(')')) {
                for raw in inner.0.split(';') {
                    check(cancel)?;
                    if let Some(p) = parameter(raw) {
                        if result.parameters.len() >= 1024 {
                            return Err(Error::Limit("parameters"));
                        }
                        result.parameters.push(p);
                    }
                }
                result.returns = inner.1.trim_start().strip_prefix("->").and_then(parameter);
                return Ok(result);
            }
        }
    }
    let mut numbered = std::collections::BTreeMap::new();
    let mut variadic = None;
    for (offset, line) in lines(source) {
        check(cancel)?;
        let trimmed = line.trim_start_matches([' ', '\t', '\u{feff}']);
        let start = offset + line.len() - trimmed.len();
        if mask.get(start) != Some(&Mask::Code) {
            continue;
        }
        let Some((command, args)) = trimmed.split_once('(') else {
            continue;
        };
        let command = command.split(':').next().unwrap_or("").trim();
        let ty = match command {
            "C_TEXT" | "C_STRING" => "Text",
            "C_LONGINT" => "Longint",
            "C_INTEGER" => "Integer",
            "C_REAL" => "Real",
            "C_BOOLEAN" => "Boolean",
            "C_DATE" => "Date",
            "C_TIME" => "Time",
            "C_POINTER" => "Pointer",
            "C_PICTURE" => "Picture",
            "C_BLOB" => "Blob",
            "C_OBJECT" => "Object",
            "C_COLLECTION" => "Collection",
            "C_VARIANT" => "Variant",
            _ => continue,
        };
        let Some((args, _)) = args.split_once(')') else {
            continue;
        };
        for arg in args.split(';').map(str::trim) {
            check(cancel)?;
            if let Some(raw) = arg.strip_prefix("${").and_then(|s| s.strip_suffix('}')) {
                if let Ok(n) = raw.parse::<usize>() {
                    if (1..=1024).contains(&n) {
                        variadic = Some(Parameter {
                            name: format!("${{{n}}}…"),
                            type_name: Some(ty.into()),
                        });
                    }
                }
            } else if let Some(n) = arg
                .strip_prefix('$')
                .and_then(|s| s.parse::<usize>().ok())
                .filter(|n| *n <= 1024)
            {
                let p = Parameter {
                    name: format!("${n}"),
                    type_name: Some(ty.into()),
                };
                if n == 0 {
                    result.returns = Some(p);
                } else {
                    numbered.insert(n, p);
                }
            }
        }
    }
    if let Some(highest) = numbered.keys().next_back().copied() {
        result.parameters = (1..=highest)
            .map(|n| {
                numbered.remove(&n).unwrap_or(Parameter {
                    name: format!("${n}"),
                    type_name: None,
                })
            })
            .collect();
    }
    if let Some(p) = variadic {
        result.parameters.push(p);
    }
    Ok(result)
}

pub(crate) fn completion_properties(c: char) -> u8 {
    tokens::completion_properties(c)
}
pub(crate) fn completion_range_is_code(
    source: &str,
    range: std::ops::Range<usize>,
    cancel: &Cancellation,
) -> Result<bool> {
    let mask = lexical::mask(source, lexical::StringPolicy::UntilLf, cancel)?;
    Ok(mask
        .get(range)
        .is_some_and(|part| part.iter().all(|kind| *kind == Mask::Code)))
}

pub(crate) fn target_keyword(name: &str) -> bool { tokens::target_keyword(name) }
pub(crate) fn target_builtin(name: &str) -> bool { tokens::target_builtin(name) }
