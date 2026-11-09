//! Die beiden vorhandenen Mac-Zielprovider; Dateizugriffe bleiben beim aufrufenden Worker.
use crate::{four_d, icu, Cancellation, Error, Limits, Utf16Range};
use std::path::{Path, PathBuf};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    FourD,
    Markdown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
    Limit,
    MultipleFunctions(String),
    MissingTarget(String),
    MissingHeading(String),
    RelativeNeedsFile,
    MissingFile(String),
    InvalidAddress(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    OpenFile(PathBuf),
    Jump(Utf16Range),
    OpenUrl(String),
    SearchProject(String),
    NotFound(Notice),
}
pub struct Context<'a> {
    pub source: &'a str,
    pub location: usize,
    pub format: Format,
    pub document: Option<&'a Path>,
    pub project: Option<&'a Path>,
}
pub fn format(name: &str) -> Option<Format> {
    match Path::new(name)
        .extension()?
        .to_str()?
        .to_lowercase()
        .as_str()
    {
        "4dm" => Some(Format::FourD),
        "md" | "markdown" => Some(Format::Markdown),
        _ => None,
    }
}
fn limits(source: &str, cancel: &Cancellation) -> Result<(), Error> {
    cancel.check()?;
    if source.len() > 10 * 1024 * 1024 {
        return Err(Error::Limit);
    }
    Ok(())
}
pub fn phrase(
    source: &str,
    location: usize,
    cancel: &Cancellation,
) -> Result<Option<Utf16Range>, Error> {
    limits(source, cancel)?;
    let units = source.encode_utf16().collect::<Vec<_>>();
    if location > units.len() {
        return Ok(None);
    }
    let at = |n: usize| units.get(n).and_then(|v| char::from_u32(u32::from(*v)));
    let word = |c: char| c == '_' || four_d::completion_properties(c) & 3 != 0;
    let mut anchor = location;
    if !at(anchor).is_some_and(word) {
        let Some(n) = anchor.checked_sub(1).filter(|n| at(*n).is_some_and(word)) else {
            return Ok(None);
        };
        anchor = n;
    }
    let mut start = anchor;
    while start > 0 {
        cancel.check()?;
        if at(start - 1).is_some_and(word) {
            start -= 1;
        } else if start >= 2 && at(start - 1) == Some(' ') && at(start - 2).is_some_and(word) {
            start -= 2;
        } else {
            break;
        }
    }
    let mut end = anchor + 1;
    while end < units.len() {
        cancel.check()?;
        if at(end).is_some_and(word) {
            end += 1;
        } else if at(end) == Some(' ') && at(end + 1).is_some_and(word) {
            end += 2;
        } else {
            break;
        }
    }
    Ok(Some(Utf16Range {
        location: start,
        length: end - start,
    }))
}
fn containing(
    source: &str,
    location: usize,
    pattern: &str,
    cancel: &Cancellation,
) -> Result<Option<Vec<Option<Utf16Range>>>, Error> {
    let mut regex = icu::Regex::new(
        pattern,
        source,
        true,
        Limits {
            regex_time_ms: 100,
            ..Default::default()
        },
        cancel,
    )?;
    let mut count = 0;
    while let Some(groups) = regex.next()? {
        count += 1;
        if count > 100_000 {
            return Err(Error::Limit);
        }
        if groups[0].is_some_and(|r| location >= r.location && location < r.location + r.length) {
            return Ok(Some(groups));
        }
    }
    Ok(None)
}
pub fn link_target(
    source: &str,
    location: usize,
    cancel: &Cancellation,
) -> Result<Option<String>, Error> {
    limits(source, cancel)?;
    if let Some(groups) = containing(source, location, r#"!?\[[^\]\n]*\]\(([^)\n]+)\)"#, cancel)? {
        let mut target = &source[groups[1].ok_or(Error::InvalidRange)?.byte_range(source)?];
        if let Some(at) = target.find(" \"") {
            target = &target[..at];
        }
        return Ok(Some(
            target
                .trim_matches(|c: char| c.is_whitespace() && !matches!(c, '\n' | '\r'))
                .to_owned(),
        ));
    }
    for (pattern, group, trim) in [
        (r"<((?:https?|mailto)[^>\s]+)>", 1, false),
        (r"https?://[^\s<>()\[\]]+", 0, true),
    ] {
        if let Some(groups) = containing(source, location, pattern, cancel)? {
            let target = &source[groups[group]
                .ok_or(Error::InvalidRange)?
                .byte_range(source)?];
            return Ok(Some(
                if trim {
                    target.trim_end_matches(['.', ',', ';', ':', '!', '?', '…'])
                } else {
                    target
                }
                .to_owned(),
            ));
        }
    }
    Ok(None)
}
fn slug(source: &str, template: &icu::Regex) -> Result<String, Error> {
    let lowered = source.to_lowercase();
    let mut regex = template.with_text(&lowered)?;
    let mut output = Vec::new();
    let mut previous = 0;
    while let Some(groups) = regex.next()? {
        let range = groups[0].ok_or(Error::InvalidRange)?;
        output.extend_from_slice(&regex.text_units()[previous..range.location]);
        if !output.is_empty() {
            output.push(u16::from(b'-'));
        }
        previous = range.location + range.length;
    }
    output.extend_from_slice(&regex.text_units()[previous..]);
    if output.last() == Some(&u16::from(b'-')) {
        output.pop();
    }
    String::from_utf16(&output).map_err(|_| Error::InvalidRange)
}
pub fn heading_range(
    source: &str,
    anchor: &str,
    cancel: &Cancellation,
) -> Result<Option<Utf16Range>, Error> {
    limits(source, cancel)?;
    let mut regex = icu::Regex::new(
        r"(?m)^#{1,6}[\t ]+(.+)$",
        source,
        true,
        Limits {
            regex_time_ms: 100,
            ..Default::default()
        },
        cancel,
    )?;
    let wanted = anchor.to_lowercase();
    let slug_pattern =
        icu::Regex::new(r"[^\p{L}\p{N}\p{M}]+", "", true, Limits::default(), cancel)?;
    let mut count = 0;
    while let Some(groups) = regex.next()? {
        count += 1;
        if count > 100_000 {
            return Err(Error::Limit);
        }
        let title = groups[1].ok_or(Error::InvalidRange)?;
        let heading =
            String::from_utf16(&regex.text_units()[title.location..title.location + title.length])
                .map_err(|_| Error::InvalidRange)?;
        if slug(heading.trim(), &slug_pattern)? == wanted {
            return Ok(groups[0]);
        }
    }
    Ok(None)
}
fn decode_path(value: &str) -> String {
    let mut bytes = Vec::with_capacity(value.len());
    let input = value.as_bytes();
    let mut n = 0;
    while n < input.len() {
        if input[n] == b'%' {
            let decoded = input
                .get(n + 1..n + 3)
                .and_then(|s| std::str::from_utf8(s).ok())
                .and_then(|s| u8::from_str_radix(s, 16).ok());
            let Some(decoded) = decoded else {
                return value.into();
            };
            bytes.push(decoded);
            n += 3;
        } else {
            bytes.push(input[n]);
            n += 1;
        }
    }
    String::from_utf8(bytes).unwrap_or_else(|_| value.into())
}
fn standardized(path: PathBuf) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            _ => out.push(component.as_os_str()),
        }
    }
    out
}
fn roots(context: &Context<'_>, is_directory: &impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let mut add = |path: PathBuf| {
        if !roots.contains(&path) && is_directory(&path) {
            roots.push(path);
        }
    };
    if let Some(document) = context.document {
        let mut current = document.parent();
        for _ in 0..8 {
            let Some(path) = current else {
                break;
            };
            if path.file_name().is_some_and(|n| n == "Sources")
                && path
                    .parent()
                    .and_then(Path::file_name)
                    .is_some_and(|n| n == "Project")
            {
                add(path.into());
            }
            current = path.parent();
        }
    }
    if let Some(project) = context.project {
        add(project.join("Project/Sources"));
        add(project.join("Sources"));
    }
    roots
}
pub fn resolve(
    context: Context<'_>,
    is_directory: impl Fn(&Path) -> bool,
    find: impl Fn(&Path) -> Option<PathBuf>,
    cancel: &Cancellation,
) -> Result<Option<Action>, Error> {
    limits(context.source, cancel)?;
    match context.format {
        Format::FourD => {
            let Some(range) = phrase(context.source, context.location, cancel)? else {
                return Ok(None);
            };
            let value = &context.source[range.byte_range(context.source)?];
            let mut words = value.trim().split(' ').collect::<Vec<_>>();
            if let Some(at) = words
                .iter()
                .position(|w| w.eq_ignore_ascii_case("function"))
                .filter(|at| {
                    words[..*at].iter().all(|w| {
                        matches!(
                            w.to_ascii_lowercase().as_str(),
                            "exposed" | "local" | "server" | "shared" | "onhttpget"
                        )
                    })
                })
            {
                words.drain(..at);
            }
            let leading = words
                .iter()
                .take_while(|w| four_d::target_keyword(&w.to_lowercase()))
                .count();
            let name = words[leading..].join(" ");
            if !name
                .chars()
                .next()
                .is_some_and(|c| four_d::completion_properties(c) & 1 != 0)
                || four_d::target_builtin(&name.to_lowercase())
            {
                return Ok(None);
            }
            let definitions = four_d::Analysis::outline(context.source, cancel).map_err(|e| {
                if e == four_d::Error::Cancelled {
                    Error::Cancelled
                } else {
                    Error::Limit
                }
            })?;
            if definitions.len() >= four_d::MAX_DEFINITIONS {
                return Ok(Some(Action::NotFound(Notice::Limit)));
            }
            // NSString.caseInsensitiveCompare faltet auch ß/SS und finales Sigma.
            // Der gepinnte ICU-Vergleich erhält diese Mehrzeichen-Zuordnung.
            let matcher = icu::Regex::new(
                &format!(r"\A\Q{name}\E\z"),
                "",
                false,
                Limits::default(),
                cancel,
            )?;
            let mut first = None;
            for definition in definitions
                .iter()
                .filter(|d| d.kind == four_d::Kind::Function)
            {
                let mut candidate = matcher.with_text(&definition.name)?;
                if candidate.next()?.is_some() {
                    if first.is_some() {
                        return Ok(Some(Action::NotFound(Notice::MultipleFunctions(name))));
                    }
                    first = Some(definition);
                }
            }
            if let Some(definition) = first {
                return Ok(Some(Action::Jump(Utf16Range {
                    location: definition.span.utf16.start,
                    length: definition.span.utf16.len(),
                })));
            }
            for root in roots(&context, &is_directory) {
                cancel.check()?;
                for folder in ["Methods", "Classes"] {
                    if let Some(path) = find(&root.join(folder).join(format!("{name}.4dm"))) {
                        return Ok(Some(Action::OpenFile(path)));
                    }
                }
            }
            Ok(Some(
                if context.project.is_some() || context.document.is_some() {
                    Action::SearchProject(name)
                } else {
                    Action::NotFound(Notice::MissingTarget(name))
                },
            ))
        }
        Format::Markdown => {
            let Some(target) = link_target(context.source, context.location, cancel)? else {
                return Ok(None);
            };
            if target.starts_with("http://")
                || target.starts_with("https://")
                || target.starts_with("mailto:")
            {
                return Ok(Some(Action::OpenUrl(target)));
            }
            if let Some(anchor) = target.strip_prefix('#') {
                return Ok(Some(match heading_range(context.source, anchor, cancel)? {
                    Some(range) => Action::Jump(range),
                    None => Action::NotFound(Notice::MissingHeading(target)),
                }));
            }
            let path = target.split('#').next().unwrap_or_default();
            let decoded = decode_path(path);
            if decoded.is_empty() {
                return Ok(None);
            }
            let resolved = if Path::new(&decoded).is_absolute() {
                PathBuf::from(&decoded)
            } else if let Some(parent) = context.document.and_then(Path::parent) {
                parent.join(&decoded)
            } else {
                return Ok(Some(Action::NotFound(Notice::RelativeNeedsFile)));
            };
            let resolved = standardized(resolved);
            Ok(Some(match find(&resolved) {
                Some(path) => Action::OpenFile(path),
                None => Action::NotFound(Notice::MissingFile(decoded)),
            }))
        }
    }
}
