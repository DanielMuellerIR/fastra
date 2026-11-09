//! Begrenzte XPath-Quellnavigation. roxmltree validiert allein die XML-Struktur.
use crate::Cancellation;
use std::{ops::Range, sync::Arc};
use unicode_normalization::UnicodeNormalization;
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub source_bytes: usize,
    pub start_tag_bytes: usize,
    pub attributes_per_element: usize,
    pub nodes: usize,
    pub attributes: usize,
    pub depth: usize,
    pub results: usize,
    pub work: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            source_bytes: 4 * 1024 * 1024,
            start_tag_bytes: 8192,
            attributes_per_element: 128,
            nodes: 100_000,
            attributes: 100_000,
            depth: 32,
            results: 10_000,
            work: 10_000_000,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    Cancelled,
    Limit(&'static str),
    DtdForbidden,
    Xml {
        message: String,
        line: u32,
        column: u32,
    },
    Empty,
    Malformed(String),
    Unsupported(String),
    InvalidOffset,
}
type Result<T> = std::result::Result<T, Error>;
fn check(cancel: &Cancellation) -> Result<()> {
    cancel.check().map_err(|_| Error::Cancelled)
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Position {
    pub character: usize,
    pub utf16: usize,
    pub line: usize,
    pub column: usize,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub bytes: Range<usize>,
    pub characters: Range<usize>,
    pub utf16: Range<usize>,
    pub line: usize,
    pub column: usize,
}
#[derive(Clone, Copy)]
struct Point {
    byte: usize,
    position: Position,
    cr: bool,
}
fn advance(point: &mut Point, c: char) {
    point.byte += c.len_utf8();
    point.position.character += 1;
    point.position.utf16 += c.len_utf16();
    if c == '\r' {
        point.position.line += 1;
        point.position.column = 1;
    } else if c == '\n' {
        if !point.cr {
            point.position.line += 1;
        }
        point.position.column = 1;
    } else {
        point.position.column += 1;
    }
    point.cr = c == '\r';
}
/// Ein-Pass-Checkpoints begrenzen jede spätere Abbildung auf höchstens 256 Skalare.
pub struct SourceMap {
    source: Arc<str>,
    points: Vec<Point>,
}
impl SourceMap {
    pub fn build(source: Arc<str>, cancel: &Cancellation) -> Result<Self> {
        Self::build_bounded(source, Limits::default().source_bytes, cancel)
    }
    pub(crate) fn build_bounded(source: Arc<str>, maximum: usize, cancel: &Cancellation) -> Result<Self> {
        check(cancel)?;
        if maximum > 10 * 1024 * 1024 || source.len() > maximum {
            return Err(Error::Limit("source bytes"));
        }
        let mut point = Point {
            byte: 0,
            position: Position {
                character: 0,
                utf16: 0,
                line: 1,
                column: 1,
            },
            cr: false,
        };
        let mut points = vec![point];
        for c in source.chars() {
            if point.position.character % 256 == 0 {
                check(cancel)?;
            }
            advance(&mut point, c);
            if point.position.character % 256 == 0 {
                points.push(point);
            }
        }
        check(cancel)?;
        Ok(Self { source, points })
    }
    pub fn position(&self, byte: usize) -> Result<Position> {
        if byte > self.source.len() || !self.source.is_char_boundary(byte) {
            return Err(Error::InvalidOffset);
        }
        let at = self.points.partition_point(|p| p.byte <= byte) - 1;
        let mut point = self.points[at];
        for c in self.source[point.byte..byte].chars() {
            advance(&mut point, c);
        }
        Ok(point.position)
    }
    pub fn span(&self, range: Range<usize>) -> Result<Span> {
        if range.start > range.end {
            return Err(Error::InvalidOffset);
        }
        let a = self.position(range.start)?;
        let b = self.position(range.end)?;
        Ok(Span {
            bytes: range,
            characters: a.character..b.character,
            utf16: a.utf16..b.utf16,
            line: a.line,
            column: a.column,
        })
    }
}
fn key(value: &str) -> String {
    value.nfc().collect()
}
struct Attribute {
    name: String,
    name_key: String,
    value: String,
    range: Range<usize>,
}
struct Element {
    name: String,
    name_key: String,
    range: Range<usize>,
    attributes: Vec<Attribute>,
    children: Vec<usize>,
    depth: usize,
    text: Option<Range<usize>>,
}
pub struct Index {
    source: Arc<str>,
    map: SourceMap,
    elements: Vec<Element>,
    roots: Vec<usize>,
    limits: Limits,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    pub span: Span,
    pub name: String,
}
fn ws(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | b'\n')
}
fn trim(source: &str, range: Range<usize>) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let mut start = range.start;
    let mut end = range.end;
    while start < end && ws(bytes[start]) {
        start += 1;
    }
    while end > start && ws(bytes[end - 1]) {
        end -= 1;
    }
    (start < end).then_some(start..end)
}
fn decoded(raw: &str) -> Result<String> {
    let mut value = String::new();
    let mut rest = raw;
    while let Some(at) = rest.find('&') {
        value.push_str(&rest[..at]);
        rest = &rest[at + 1..];
        let end = rest.find(';').ok_or(Error::InvalidOffset)?;
        let token = &rest[..end];
        let c = match token {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            _ => {
                let number = if let Some(hex) = token.strip_prefix("#x") {
                    u32::from_str_radix(hex, 16).ok()
                } else if let Some(decimal) = token.strip_prefix('#') {
                    decimal.parse::<u32>().ok()
                } else {
                    None
                };
                number
                    .and_then(char::from_u32)
                    .ok_or(Error::InvalidOffset)?
            }
        };
        value.push(c);
        rest = &rest[end + 1..];
    }
    value.push_str(rest);
    Ok(value)
}
// Ausschließlich Positionen eines bereits vollständig validierten Starttags ableiten, keine XML-Struktur parsen.
fn start_ranges(source: &str, start: usize) -> Result<(Range<usize>, Vec<Attribute>, usize)> {
    let bytes = source.as_bytes();
    let mut p = start + 1;
    let begin = p;
    while p < bytes.len() && !ws(bytes[p]) && !matches!(bytes[p], b'/' | b'>') {
        p += 1;
    }
    let name = begin..p;
    let mut attributes = Vec::new();
    loop {
        while p < bytes.len() && ws(bytes[p]) {
            p += 1;
        }
        if matches!(bytes.get(p), Some(b'/' | b'>')) {
            while bytes.get(p) != Some(&b'>') {
                p += 1;
            }
            return Ok((name, attributes, p + 1));
        }
        let a = p;
        while p < bytes.len() && !ws(bytes[p]) && bytes[p] != b'=' {
            p += 1;
        }
        let range = a..p;
        while p < bytes.len() && ws(bytes[p]) {
            p += 1;
        }
        if bytes.get(p) != Some(&b'=') {
            return Err(Error::InvalidOffset);
        }
        p += 1;
        while p < bytes.len() && ws(bytes[p]) {
            p += 1;
        }
        let quote = *bytes.get(p).ok_or(Error::InvalidOffset)?;
        if !matches!(quote, b'\'' | b'"') {
            return Err(Error::InvalidOffset);
        }
        p += 1;
        let value = p;
        while p < bytes.len() && bytes[p] != quote {
            p += 1;
        }
        if p >= bytes.len() {
            return Err(Error::InvalidOffset);
        }
        attributes.push(Attribute {
            name: source[range.clone()].into(),
            name_key: key(&source[range.clone()]),
            value: key(&decoded(&source[value..p])?),
            range,
        });
        p += 1;
    }
}
fn first_text(source: &str, range: Range<usize>) -> Option<Range<usize>> {
    let mut p = range.start;
    while p < range.end {
        if source[p..range.end].starts_with("<![CDATA[") {
            let start = p + 9;
            let end = start + source[start..range.end].find("]]>")?;
            if let Some(span) = trim(source, start..end) {
                return Some(span);
            }
            p = end + 3;
        } else if source.as_bytes()[p] == b'<' {
            return None;
        } else {
            let end = source[p..range.end]
                .find('<')
                .map_or(range.end, |at| p + at);
            if let Some(span) = trim(source, p..end) {
                return Some(span);
            }
            p = end;
        }
    }
    None
}
// Nur Sicherheitsgrenzen erkennen; roxmltree bleibt der einzige Struktur-/Namensvalidator.
fn safety_scan(source: &str, limits: Limits, cancel: &Cancellation) -> Result<()> {
    let bytes = source.as_bytes();
    let mut p = 0;
    let mut depth = 0usize;
    while p < bytes.len() {
        check(cancel)?;
        let Some(at) = source[p..].find('<') else {
            break;
        };
        p += at;
        let tail = &source[p..];
        let special = if tail.starts_with("<!--") {
            Some((4, "-->"))
        } else if tail.starts_with("<![CDATA[") {
            Some((9, "]]>"))
        } else if tail.starts_with("<?") {
            Some((2, "?>"))
        } else {
            None
        };
        if let Some((skip, end)) = special {
            let Some(at) = source[p + skip..].find(end) else {
                return Ok(());
            };
            p += skip + at + end.len();
            continue;
        }
        if tail.starts_with("<!DOCTYPE") {
            return Err(Error::DtdForbidden);
        }
        if tail.starts_with("<!") {
            return Ok(());
        }
        let closing = tail.starts_with("</");
        let start = p;
        p += 1;
        let mut quote = None;
        let mut attributes = 0;
        while p < bytes.len() {
            if (p - start) % 256 == 0 {
                check(cancel)?;
            }
            if p - start >= limits.start_tag_bytes {
                return Err(Error::Limit("start tag bytes"));
            }
            let byte = bytes[p];
            if let Some(active) = quote {
                if byte == active {
                    quote = None;
                }
            } else if matches!(byte, b'\'' | b'"') {
                quote = Some(byte);
            } else if byte == b'=' {
                attributes += 1;
                if attributes > limits.attributes_per_element {
                    return Err(Error::Limit("attributes per element"));
                }
            } else if byte == b'>' {
                break;
            }
            p += 1;
        }
        if p == bytes.len() {
            return Ok(());
        }
        let mut last = p;
        while last > start && ws(bytes[last - 1]) {
            last -= 1;
        }
        if closing {
            depth = depth.saturating_sub(1);
        } else if bytes.get(last.wrapping_sub(1)) != Some(&b'/') {
            depth += 1;
            if depth > limits.depth {
                return Err(Error::Limit("depth"));
            }
        }
        p += 1;
    }
    check(cancel)
}
impl Index {
    pub fn build(source: &str, limits: Limits, cancel: &Cancellation) -> Result<Self> {
        check(cancel)?;
        let hard = Limits::default();
        if limits.source_bytes > hard.source_bytes
            || limits.start_tag_bytes > hard.start_tag_bytes
            || limits.attributes_per_element > hard.attributes_per_element
            || limits.nodes > hard.nodes
            || limits.attributes > hard.attributes
            || limits.depth > hard.depth
            || limits.results > hard.results
            || limits.work > hard.work
        {
            return Err(Error::Limit("configuration"));
        }
        if source.len() > limits.source_bytes {
            return Err(Error::Limit("source bytes"));
        }
        safety_scan(source, limits, cancel)?;
        let source: Arc<str> = source.into();
        // Diese harte begrenzte Bibliotheksphase besitzt keinen kooperativen Abbruchhook.
        let doc = roxmltree::Document::parse_with_options(
            &source,
            roxmltree::ParsingOptions {
                allow_dtd: false,
                nodes_limit: limits.nodes.min(u32::MAX as usize) as u32,
                entity_resolver: None,
            },
        )
        .map_err(|e| match e {
            roxmltree::Error::DtdDetected => Error::DtdForbidden,
            roxmltree::Error::NodesLimitReached
            | roxmltree::Error::AttributesLimitReached
            | roxmltree::Error::NamespacesLimitReached => Error::Limit("parser nodes/attributes"),
            other => {
                let p = other.pos();
                Error::Xml {
                    message: other.to_string(),
                    line: p.row,
                    column: p.col,
                }
            }
        })?;
        check(cancel)?;
        let prefix = &source[..doc.root_element().range().start];
        let ignored: Vec<_> = doc
            .root()
            .children()
            .filter(|n| n.is_comment() || n.is_pi())
            .map(|n| n.range())
            .collect();
        let mut cursor = 0;
        for (at, _) in prefix.match_indices("<!DOCTYPE") {
            check(cancel)?;
            while cursor < ignored.len() && ignored[cursor].end <= at {
                cursor += 1;
            }
            if ignored.get(cursor).is_none_or(|range| !range.contains(&at)) {
                return Err(Error::DtdForbidden);
            }
        }
        let mut elements: Vec<Element> = Vec::new();
        let mut roots = Vec::new();
        let mut ids = vec![usize::MAX; doc.descendants().count()];
        let mut total_attributes = 0;
        for node in doc.descendants().filter(|n| n.is_element()) {
            check(cancel)?;
            let parent = node
                .parent()
                .filter(|p| p.is_element())
                .map(|p| ids[p.id().get_usize()]);
            let depth = parent.map_or(1, |p| elements[p].depth + 1);
            if depth > limits.depth {
                return Err(Error::Limit("depth"));
            }
            let (range, attributes, end) = start_ranges(&source, node.range().start)?;
            total_attributes += attributes.len();
            if total_attributes > limits.attributes {
                return Err(Error::Limit("attributes"));
            }
            let mut cursor = end;
            let mut text = None;
            for child in node.children().filter(|n| !n.is_text()) {
                if text.is_none() {
                    text = first_text(&source, cursor..child.range().start);
                }
                cursor = child.range().end;
            }
            if text.is_none() {
                text = first_text(&source, cursor..node.range().end);
            }
            let index = elements.len();
            ids[node.id().get_usize()] = index;
            if let Some(parent) = parent {
                elements[parent].children.push(index);
            } else {
                roots.push(index);
            }
            elements.push(Element {
                name: source[range.clone()].into(),
                name_key: key(&source[range.clone()]),
                range,
                attributes,
                children: Vec::new(),
                depth,
                text,
            });
        }
        drop(doc);
        let map = SourceMap::build(source.clone(), cancel)?;
        check(cancel)?;
        Ok(Self {
            source,
            map,
            elements,
            roots,
            limits,
        })
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn element_count(&self) -> usize {
        self.elements.len()
    }
    fn children(&self, node: usize) -> &[usize] {
        if node == usize::MAX {
            &self.roots
        } else {
            &self.elements[node].children
        }
    }
    fn evaluate(&self, query: &Query, cancel: &Cancellation) -> Result<Vec<usize>> {
        let mut budget = Budget {
            left: self.limits.work,
            cancel,
        };
        let mut context = vec![usize::MAX];
        for step in &query.steps {
            let mut parents = Vec::new();
            let mut pending = context;
            let mut visited = vec![false; self.elements.len() + 1];
            while let Some(node) = pending.pop() {
                budget.use_work(1)?;
                let key = if node == usize::MAX {
                    self.elements.len()
                } else {
                    node
                };
                if visited[key] {
                    continue;
                }
                visited[key] = true;
                parents.push(node);
                if step.descendant {
                    pending.extend_from_slice(self.children(node));
                }
            }
            let mut next = Vec::new();
            for parent in parents {
                let mut matched = Vec::new();
                for &node in self.children(parent) {
                    budget.use_work(self.elements[node].name.len() + 1)?;
                    if step
                        .name
                        .as_ref()
                        .is_none_or(|name| name == &self.elements[node].name_key)
                    {
                        matched.push(node);
                    }
                }
                for predicate in &step.predicates {
                    match predicate {
                        Predicate::Position(n) => {
                            matched = matched.get(n - 1).copied().into_iter().collect();
                        }
                        Predicate::Attribute(name, value) => {
                            let mut filtered = Vec::new();
                            for node in matched {
                                let mut keep = false;
                                for attribute in &self.elements[node].attributes {
                                    budget.use_work(
                                        attribute.name.len() + attribute.value.len() + 1,
                                    )?;
                                    if &attribute.name_key == name
                                        && value.as_ref().is_none_or(|v| v == &attribute.value)
                                    {
                                        keep = true;
                                        break;
                                    }
                                }
                                if keep {
                                    filtered.push(node);
                                }
                            }
                            matched = filtered;
                        }
                    }
                }
                next.extend(matched);
            }
            let sorting = next
                .len()
                .checked_mul((usize::BITS - next.len().leading_zeros()) as usize)
                .ok_or(Error::Limit("query work"))?;
            budget.use_work(sorting)?;
            next.sort_unstable();
            next.dedup();
            context = next;
            if context.is_empty() {
                break;
            }
        }
        check(cancel)?;
        Ok(context)
    }
    pub fn query(&self, input: &str, cancel: &Cancellation) -> Result<Vec<Match>> {
        check(cancel)?;
        let query = Query::parse(input)?;
        let context = self.evaluate(&query, cancel)?;
        let mut matches = Vec::new();
        for node in context {
            check(cancel)?;
            let element = &self.elements[node];
            let range = match &query.terminal {
                Terminal::Element => Some(element.range.clone()),
                Terminal::Text => element.text.clone(),
                Terminal::Attribute(name) => element
                    .attributes
                    .iter()
                    .find(|a| &a.name_key == name)
                    .map(|a| a.range.clone()),
            };
            if let Some(range) = range {
                if matches.len() >= self.limits.results {
                    return Err(Error::Limit("results"));
                }
                matches.push(Match {
                    span: self.map.span(range)?,
                    name: element.name.clone(),
                });
            }
        }
        Ok(matches)
    }
    pub fn completions(
        &self,
        input: &str,
        limit: usize,
        cancel: &Cancellation,
    ) -> Result<Vec<String>> {
        check(cancel)?;
        if input.len() > 4096 {
            return Err(Error::Limit("query bytes"));
        }
        let (raw, partial) = split_completion(input);
        let descendant = raw.is_empty() || raw.ends_with("//");
        let path = raw.strip_suffix("//").unwrap_or(raw);
        let context = if path.is_empty() || path == "/" {
            vec![usize::MAX]
        } else {
            let query = Query::parse(path)?;
            if !matches!(query.terminal, Terminal::Element) {
                return Ok(Vec::new());
            }
            self.evaluate(&query, cancel)?
        };
        let mut candidates = Vec::new();
        if partial.starts_with('@') {
            for node in context.into_iter().filter(|n| *n != usize::MAX) {
                for attr in &self.elements[node].attributes {
                    candidates.push(format!("@{}", attr.name));
                }
            }
        } else {
            let mut visited = vec![false; self.elements.len()];
            let mut pending = Vec::new();
            for node in context.iter().rev() {
                pending.extend(self.children(*node).iter().rev().copied());
            }
            while let Some(node) = pending.pop() {
                check(cancel)?;
                if visited[node] {
                    continue;
                }
                visited[node] = true;
                candidates.push(self.elements[node].name.clone());
                if descendant {
                    pending.extend(self.elements[node].children.iter().rev().copied());
                }
            }
        }
        let prefix = key(&partial.to_lowercase());
        let mut result = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for candidate in candidates {
            check(cancel)?;
            if key(&candidate.to_lowercase()).starts_with(&prefix) && seen.insert(key(&candidate)) {
                result.push(candidate);
                if result.len() >= limit.min(32) {
                    break;
                }
            }
        }
        if limit == 0 {
            result.clear();
        }
        Ok(result)
    }
}
struct Budget<'a> {
    left: usize,
    cancel: &'a Cancellation,
}
impl Budget<'_> {
    fn use_work(&mut self, n: usize) -> Result<()> {
        check(self.cancel)?;
        self.left = self.left.checked_sub(n).ok_or(Error::Limit("query work"))?;
        Ok(())
    }
}
#[derive(Debug, PartialEq, Eq)]
enum Predicate {
    Position(usize),
    Attribute(String, Option<String>),
}
struct Step {
    descendant: bool,
    name: Option<String>,
    predicates: Vec<Predicate>,
}
enum Terminal {
    Element,
    Attribute(String),
    Text,
}
struct Query {
    steps: Vec<Step>,
    terminal: Terminal,
}
fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_alphabetic() || c == '_')
        && chars.all(|c| {
            c.is_alphanumeric()
                || matches!(c, '_' | '-' | '.' | ':')
                || unicode_normalization::char::is_combining_mark(c)
        })
}
impl Query {
    fn parse(input: &str) -> Result<Self> {
        if input.len() > 4096 {
            return Err(Error::Limit("query bytes"));
        }
        let mut rest = input.trim_matches(|c: char| {
            c == '\t'
                || (c.is_whitespace()
                    && !matches!(
                        c,
                        '\r' | '\n' | '\x0b' | '\x0c' | '\u{85}' | '\u{2028}' | '\u{2029}'
                    ))
        });
        if rest.is_empty() {
            return Err(Error::Empty);
        }
        for token in ["::", ".."] {
            if rest.contains(token) {
                return Err(Error::Unsupported(token.into()));
            }
        }
        let mut descendant = !rest.starts_with('/') || rest.starts_with("//");
        if rest.starts_with("//") {
            rest = &rest[2..];
        } else if rest.starts_with('/') {
            rest = &rest[1..];
        }
        let mut steps = Vec::new();
        let mut terminal = Terminal::Element;
        let mut predicate_count = 0;
        while !rest.is_empty() {
            if let Some(attr) = rest.strip_prefix('@') {
                if !valid_name(attr) {
                    return Err(Error::Malformed(rest.into()));
                }
                terminal = Terminal::Attribute(key(attr));
                break;
            }
            if rest.starts_with("text()") {
                if rest != "text()" {
                    return Err(Error::Malformed(rest.into()));
                }
                terminal = Terminal::Text;
                break;
            }
            let end = rest.find(['/', '[']).unwrap_or(rest.len());
            let name = &rest[..end];
            rest = &rest[end..];
            let name = if name == "*" {
                None
            } else if valid_name(name) {
                Some(key(name))
            } else if name.contains('(') {
                return Err(Error::Unsupported(name.into()));
            } else {
                return Err(Error::Malformed(name.into()));
            };
            let mut predicates = Vec::new();
            while rest.starts_with('[') {
                predicate_count += 1;
                if predicate_count > 128 {
                    return Err(Error::Limit("predicates"));
                }
                let mut quote = None;
                let mut close = None;
                for (at, c) in rest.char_indices().skip(1) {
                    if let Some(active) = quote {
                        if active == c {
                            quote = None;
                        }
                    } else if c == '\'' || c == '"' {
                        quote = Some(c);
                    } else if c == ']' {
                        close = Some(at);
                        break;
                    }
                }
                let close = close.ok_or_else(|| Error::Malformed(rest.into()))?;
                let body = &rest[1..close];
                rest = &rest[close + 1..];
                if let Ok(n) = body.parse::<usize>() {
                    if n > 0 {
                        predicates.push(Predicate::Position(n));
                        continue;
                    }
                }
                if let Some(attr) = body.strip_prefix('@') {
                    if let Some((name, value)) = attr.split_once('=') {
                        if !valid_name(name)
                            || value.len() < 2
                            || !matches!(value.as_bytes()[0], b'\'' | b'"')
                            || value.as_bytes().first() != value.as_bytes().last()
                        {
                            return Err(Error::Malformed(body.into()));
                        }
                        let inner = &value[1..value.len() - 1];
                        if inner.contains(value.as_bytes()[0] as char) {
                            return Err(Error::Unsupported(body.into()));
                        }
                        predicates.push(Predicate::Attribute(key(name), Some(key(inner))));
                    } else {
                        if !valid_name(attr) {
                            return Err(Error::Malformed(body.into()));
                        }
                        predicates.push(Predicate::Attribute(key(attr), None));
                    }
                } else {
                    return Err(Error::Unsupported(format!("[{body}]")));
                }
            }
            if steps.len() >= 128 {
                return Err(Error::Limit("steps"));
            }
            steps.push(Step {
                descendant,
                name,
                predicates,
            });
            if rest.starts_with("//") {
                descendant = true;
                rest = &rest[2..];
            } else if rest.starts_with('/') {
                descendant = false;
                rest = &rest[1..];
            } else if rest.is_empty() {
                break;
            } else {
                return Err(Error::Malformed(rest.into()));
            }
            if rest.is_empty() {
                return Err(Error::Malformed(input.into()));
            }
        }
        if steps.is_empty() {
            return Err(Error::Malformed(input.into()));
        }
        Ok(Self { steps, terminal })
    }
}
pub fn split_completion(input: &str) -> (&str, &str) {
    let Some(at) = input.rfind('/') else {
        return ("", input);
    };
    let path = &input[..at];
    let partial = &input[at + 1..];
    if path.ends_with('/') || path.is_empty() {
        (&input[..at + 1], partial)
    } else {
        (path, partial)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn index(xml: &str) -> Index {
        Index::build(xml, Limits::default(), &Cancellation::default()).unwrap()
    }
    fn values(xml: &str, query: &str) -> Vec<String> {
        let index = index(xml);
        index
            .query(query, &Cancellation::default())
            .unwrap()
            .iter()
            .map(|m| xml[m.span.bytes.clone()].into())
            .collect()
    }
    #[test]
    fn actual_swift_reference_values_and_utf16_positions() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../tests/fixtures/xpath-swift-reference.json"))
                .unwrap();
        let mut compared = 0;
        let mut validity_gap = 0;
        for row in cases {
            if row.get("error").is_some() {
                let xml = row["xml"].as_str().unwrap();
                let matches = index(xml)
                    .query(row["query"].as_str().unwrap(), &Cancellation::default())
                    .unwrap();
                assert_eq!(matches.len(), 1);
                assert_eq!(matches[0].span.utf16.len(), 2);
                validity_gap += 1;
                continue;
            }
            let xml = row["xml"].as_str().unwrap();
            let query = row["query"].as_str().unwrap();
            let matches = index(xml).query(query, &Cancellation::default()).unwrap();
            let values: Vec<_> = matches
                .iter()
                .map(|m| xml[m.span.bytes.clone()].to_owned())
                .collect();
            let spans: Vec<_> = matches
                .iter()
                .map(|m| vec![m.span.utf16.start, m.span.utf16.len()])
                .collect();
            assert_eq!(
                serde_json::to_value(values).unwrap(),
                row["values"],
                "{query}"
            );
            assert_eq!(
                serde_json::to_value(spans).unwrap(),
                row["utf16"],
                "{query}"
            );
            compared += 1;
        }
        assert_eq!(compared, 11);
        assert_eq!(validity_gap, 1);
    }
    #[test]
    fn swift_predicate_order_and_parent_positions() {
        let xml="<r><g><a id='1'/><a id='2' kind='x'/><g><a id='3' kind='x'/><a id='4'/></g></g><g><a id='5' kind='x'/></g></r>";
        let index = index(xml);
        for (query, expected) in [
            ("//g//a[1]/@id", vec!["id", "id", "id"]),
            ("//g//a[2]/@id", vec!["id", "id"]),
            ("//g//a[2][@kind='x']", vec!["a"]),
            ("//g//a[@kind='x'][1]", vec!["a", "a", "a"]),
        ] {
            assert_eq!(
                index
                    .query(query, &Cancellation::default())
                    .unwrap()
                    .iter()
                    .map(|m| xml[m.span.bytes.clone()].to_owned())
                    .collect::<Vec<_>>(),
                expected
            );
        }
        let xml = "<r><a id='A'/><a id='B'/></r>";
        assert!(values(xml, "/r/a[1][@id='B']").is_empty());
        assert_eq!(values(xml, "/r/a[@id='B'][1]"), ["a"]);
        assert_eq!(values(xml, "/r/a[2][@id='B']"), ["a"]);
        assert!(values(xml, "/r/a[@id='B'][2]").is_empty());
    }
    #[test]
    fn swift_sample_unicode_crlf_original_offsets() {
        let xml="<?xml version='1.0'?>\r\n<bibliothek name='Köln 🙂'>\r\n<!-- äöü --><buch id='1' sprache='de'><titel>Süße Grüße</titel></buch><buch id='42' sprache='en'><titel>Emoji 🚀 Handbuch</titel></buch><zeitschrift id='7'/></bibliothek>";
        let index = index(xml);
        for element in &index.elements {
            let span = index.map.span(element.range.clone()).unwrap();
            assert_eq!(&xml[span.bytes.clone()], element.name);
            assert_eq!(
                xml[..span.bytes.start].chars().count(),
                span.characters.start
            );
            assert_eq!(
                xml[..span.bytes.start].encode_utf16().count(),
                span.utf16.start
            );
            for attr in &element.attributes {
                assert_eq!(&xml[attr.range.clone()], attr.name);
            }
        }
        assert_eq!(values(xml, "/bibliothek/buch/titel"), ["titel", "titel"]);
        assert!(values(xml, "/buch").is_empty());
        assert_eq!(
            values(xml, "//titel/text()"),
            ["Süße Grüße", "Emoji 🚀 Handbuch"]
        );
        assert_eq!(values(xml, "buch//titel"), ["titel", "titel"]);
        assert_eq!(values(xml, "//buch/@sprache"), ["sprache", "sprache"]);
        assert_eq!(values(xml, "/bibliothek/*[2]"), ["buch"]);
        assert_eq!(values(xml, "\u{a0}//titel\u{a0}"), ["titel", "titel"]);
    }
    #[test]
    fn swift_entities_raw_attribute_whitespace_and_qnames() {
        let xml =
            "<r xmlns:p='urn:x'><p:a p:id='A&amp;B' raw='a\r\n\tb'/><p:a p:id='&#x1F680;'/></r>";
        assert_eq!(values(xml, "//p:a[@p:id='A&B']/@p:id"), ["p:id"]);
        assert_eq!(values(xml, "//p:a[@p:id='🚀']"), ["p:a"]);
        assert_eq!(values(xml, "//p:a[@raw='a\r\n\tb']"), ["p:a"]);
        assert!(values(xml, "//p:a[@raw='a   b']").is_empty());
        assert_eq!(values(xml, "//*[@xmlns:p]/@xmlns:p"), ["xmlns:p"]);
        assert_eq!(values("<r xmlns='urn'><a/></r>", "//a"), ["a"]);
        assert_eq!(values("<r><buch id=']'/></r>", "//buch[@id=']']"), ["buch"]);
    }
    #[test]
    fn swift_cdata_first_direct_text_and_non_elements() {
        let xml="<?pi <!-- ?><r><!-- <fake> --><![CDATA[   ]]><![CDATA[  🚀 Start  ]]><a>🚀 Anfang</a> tail</r>";
        assert_eq!(values(xml, "/r/text()"), ["🚀 Start"]);
        assert_eq!(values(xml, "//a/text()"), ["🚀 Anfang"]);
        assert_eq!(
            values("<r> \r\n<![CDATA[  🚀 hi  ]]>suffix</r>", "/r/text()"),
            ["🚀 hi"]
        );
        assert_eq!(
            values("<r>AT&amp;T<![CDATA[x]]></r>", "/r/text()"),
            ["AT&amp;T"]
        );
        assert_eq!(
            values("<r><!-- a --><a/><?pi x?><b/></r>", "//*"),
            ["r", "a", "b"]
        );
    }
    #[test]
    fn swift_unsupported_and_malformed_queries() {
        for query in [
            "//a/ancestor::b",
            "//a/..",
            "count(//a)",
            "//a[last()]",
            "//a[0]",
            "//a[-1]",
            "//a[@id='1' or @id='2']",
        ] {
            assert!(
                matches!(Query::parse(query), Err(Error::Unsupported(_))),
                "{query}"
            );
        }
        for query in [
            "/",
            "//",
            "@id",
            "text()",
            "//a/",
            "//a[@id='42",
            "//a[@=1]",
            "//a|b",
        ] {
            assert!(Query::parse(query).is_err(), "{query}");
        }
        for query in [
            "//ancestor",
            "//following-item",
            "/preceding/value",
            "//e\u{301}",
        ] {
            assert!(Query::parse(query).is_ok(), "{query}");
        }
    }
    #[test]
    fn swift_autocomplete() {
        let index = index(
            "<bibliothek><buch id='1' sprache='de'><titel/></buch><zeitschrift/></bibliothek>",
        );
        let c = Cancellation::default();
        assert_eq!(index.completions("/", 8, &c).unwrap(), ["bibliothek"]);
        assert_eq!(index.completions("/bibliothek/b", 8, &c).unwrap(), ["buch"]);
        assert_eq!(
            index.completions("/bibliothek/", 8, &c).unwrap(),
            ["buch", "zeitschrift"]
        );
        assert_eq!(
            index.completions("//buch/@", 8, &c).unwrap(),
            ["@id", "@sprache"]
        );
        assert_eq!(index.completions("//ti", 8, &c).unwrap(), ["titel"]);
        assert_eq!(
            index.completions("/bibliothek//ti", 8, &c).unwrap(),
            ["titel"]
        );
        assert_eq!(split_completion("/bibliothek//ti"), ("/bibliothek//", "ti"));
        assert_eq!(split_completion("//ti"), ("//", "ti"));
        assert!(index.completions("/", 0, &c).unwrap().is_empty());
    }
    #[test]
    fn invalid_xml_and_all_dtds_are_refused() {
        for xml in [
            "<a x></a>",
            "<a></a",
            "<a><!-- offen</a>",
            "<a/><b/>",
            "Text<a/>",
            "<1/>",
            "<a x='offen></a>",
            "<a><</a>",
            "<a x='1' x='2'/>",
            "<a x='<'/>",
            "<a>AT&T</a>",
            "<a>&#0;</a>",
            "<a>\u{1}</a>",
            "<a><!-- a -- b --></a>",
            "<a>Text ]]> Rest</a>",
            "<!DOCTYPE a [<!ELEMENT a EMPTY>",
        ] {
            assert!(
                Index::build(xml, Limits::default(), &Cancellation::default()).is_err(),
                "{xml}"
            );
        }
        for xml in [
            "<!DOCTYPE r><r/>",
            "<!DOCTYPE r SYSTEM 'file:///nonexistent'><r/>",
            "<!DOCTYPE r SYSTEM 'http://127.0.0.1:9/no-network'><r/>",
            "<!DOCTYPE r [<!ELEMENT r EMPTY>]><r/>",
            "<!DOCTYPE r [<!ENTITY ext SYSTEM 'file:///etc/passwd'>]><r>&ext;</r>",
        ] {
            assert!(
                matches!(
                    Index::build(xml, Limits::default(), &Cancellation::default()),
                    Err(Error::DtdForbidden)
                ),
                "{xml}"
            );
        }
        assert!(Index::build(
            "<!-- <!DOCTYPE r> --><r><![CDATA[<!DOCTYPE r>]]></r>",
            Limits::default(),
            &Cancellation::default()
        )
        .is_ok());
    }
    #[test]
    fn bounded_large_deep_and_overlapping_documents() {
        let mut xml = "<wurzel>".to_owned();
        for i in 1..=5000 {
            xml += &format!("<eintrag id='{i}'><wert>Nr. {i} — Grüße 🙂</wert></eintrag>");
        }
        xml += "</wurzel>";
        let index = index(&xml);
        assert_eq!(index.element_count(), 10001);
        assert_eq!(
            index
                .query("//eintrag[@id='4711']/wert", &Cancellation::default())
                .unwrap()
                .len(),
            1
        );
        let xml = "<n>".repeat(12000) + "<ziel/>" + &"</n>".repeat(12000);
        assert!(matches!(
            Index::build(&xml, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("depth"))
        ));
        let xml = "<n>".repeat(31) + "<ziel/>" + &"</n>".repeat(31);
        assert_eq!(values(&xml, "//n//ziel"), ["ziel"]);
        let at_limit = "<n>".repeat(32) + "safe" + &"</n>".repeat(32);
        assert_eq!(values(&at_limit, "//n/text()"), ["safe"]);
    }
    #[test]
    fn cancellation_and_complete_limits() {
        let xml = "<r><a/><a/></r>";
        let mut limits = Limits {
            results: 1,
            ..Limits::default()
        };
        let index = Index::build(xml, limits, &Cancellation::default()).unwrap();
        assert!(matches!(
            index.query("//a", &Cancellation::default()),
            Err(Error::Limit("results"))
        ));
        limits.results = 10;
        limits.work = 1;
        let index = Index::build(xml, limits, &Cancellation::default()).unwrap();
        assert!(matches!(
            index.query("//*", &Cancellation::default()),
            Err(Error::Limit("query work"))
        ));
        let cancelled = Cancellation::default();
        cancelled.cancel();
        assert!(matches!(
            Index::build(xml, Limits::default(), &cancelled),
            Err(Error::Cancelled)
        ));
        assert_eq!(index.query("//a", &cancelled), Err(Error::Cancelled));
        for limits in [
            Limits {
                source_bytes: 1,
                ..Limits::default()
            },
            Limits {
                nodes: 2,
                ..Limits::default()
            },
            Limits {
                attributes: 0,
                ..Limits::default()
            },
            Limits {
                depth: 1,
                ..Limits::default()
            },
        ] {
            assert!(Index::build("<r a='1'><a/></r>", limits, &Cancellation::default()).is_err());
        }
        assert_eq!(
            values(
                &("<r>".to_owned() + &"x".repeat(8193) + "</r>"),
                "/r/text()"
            )[0]
            .len(),
            8193
        );
    }
    #[test]
    fn reusable_map_is_exact_at_every_unicode_boundary() {
        let xml = "A🚀e\u{301}\r\n雪\rX\nZ";
        let map = SourceMap::build(xml.into(), &Cancellation::default()).unwrap();
        for (byte, _) in xml.char_indices().chain(std::iter::once((xml.len(), ' '))) {
            let p = map.position(byte).unwrap();
            assert_eq!(p.character, xml[..byte].chars().count());
            assert_eq!(p.utf16, xml[..byte].encode_utf16().count());
        }
        assert_eq!(map.position(xml.find('雪').unwrap()).unwrap().line, 2);
        assert_eq!(map.position(xml.find('X').unwrap()).unwrap().line, 3);
        assert_eq!(map.position(xml.find('Z').unwrap()).unwrap().line, 4);
        assert_eq!(map.position(2), Err(Error::InvalidOffset));
    }
    #[test]
    fn safety_lex_skips_fake_tags_and_bounds_real_depth_before_parse() {
        let xml = "<r a='> = />'><![CDATA[<n><n></r>]]><!-- <n></r> --><?pi <n></r>?></r>";
        assert!(Index::build(
            xml,
            Limits {
                depth: 1,
                ..Limits::default()
            },
            &Cancellation::default()
        )
        .is_ok());
        let opening = "<n><![CDATA[</n>]]><!-- </n> --><?pi </n>?>";
        let malicious = opening.repeat(33) + &"</n>".repeat(33);
        assert!(matches!(
            Index::build(&malicious, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("depth"))
        ));
        let attrs = (0..128).map(|n| format!(" a{n}='x'")).collect::<String>();
        assert!(Index::build(
            &format!("<r{attrs}/>"),
            Limits::default(),
            &Cancellation::default()
        )
        .is_ok());
        assert!(matches!(
            Index::build(
                &format!("<r{attrs} a128='x'/>"),
                Limits::default(),
                &Cancellation::default()
            ),
            Err(Error::Limit("attributes per element"))
        ));
        let exact = "<r a='".to_owned() + &"x".repeat(8183) + "'/>";
        assert_eq!(exact.len(), 8192);
        assert!(Index::build(&exact, Limits::default(), &Cancellation::default()).is_ok());
        let over = "<r a='".to_owned() + &"x".repeat(8184) + "'/>";
        assert!(matches!(
            Index::build(&over, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("start tag bytes"))
        ));
        let oversized = "<r a='".to_owned() + &"x".repeat(9000) + "'/>";
        assert!(matches!(
            Index::build(&oversized, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("start tag bytes"))
        ));
        let comments = "<!-- <!DOCTYPE fake> -->".repeat(1000) + "<r/>";
        assert!(Index::build(&comments, Limits::default(), &Cancellation::default()).is_ok());
    }
    #[test]
    fn adversarial_attributes_are_measured_and_prebounded() {
        let mut xml = "<r>".to_owned();
        for _ in 0..1000 {
            xml += "<a";
            for n in 0..120 {
                xml += &format!(" a{n}='x'");
            }
            xml += "/>";
        }
        xml += "</r>";
        let start = std::time::Instant::now();
        assert!(matches!(
            Index::build(&xml, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("attributes"))
        ));
        eprintln!(
            "XPATH_ADVERSARIAL attributes=120000 bytes={} elapsed_ms={}",
            xml.len(),
            start.elapsed().as_millis()
        );
        let huge = "<r ".to_owned() + &"a='x' ".repeat(2000) + "/>";
        let start = std::time::Instant::now();
        assert!(matches!(
            Index::build(&huge, Limits::default(), &Cancellation::default()),
            Err(Error::Limit("attributes per element"))
        ));
        eprintln!(
            "XPATH_PREBOUND bytes={} elapsed_us={}",
            huge.len(),
            start.elapsed().as_micros()
        );
    }
}
