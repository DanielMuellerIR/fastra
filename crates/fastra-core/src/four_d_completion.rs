//! 4D-Typeahead: reine, begrenzte Präfix- und Vorschlagsrechnung ohne Dateizugriffe.
use crate::{four_d, icu, Cancellation, Error, Utf16Range};
use std::{collections::HashSet, sync::OnceLock};
pub const AUTOMATIC_MINIMUM: usize = 2;
pub const MAX_MATCHES: usize = 200;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Command,
    Project,
    Component(String),
    Constant,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub name: String,
    pub signature: Option<String>,
    pub kind: Kind,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Component {
    pub name: String,
    pub component: String,
    pub signature: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Method {
    pub name: String,
    pub signature: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestions {
    pub range: Utf16Range,
    pub items: Vec<Candidate>,
}
struct Symbol {
    name: &'static str,
    key: String,
    signature: Option<&'static str>,
    constant: bool,
}
fn symbols() -> &'static [Symbol] {
    static SYMBOLS: OnceLock<Vec<Symbol>> = OnceLock::new();
    SYMBOLS.get_or_init(|| {
        include_str!("four_d_completion/symbols.tsv")
            .lines()
            .filter(|line| !line.starts_with('#'))
            .map(|line| {
                let fields: Vec<_> = line.split('\t').collect();
                Symbol {
                    name: fields[1],
                    key: four_d::method_key(fields[1]),
                    signature: fields.get(2).copied().filter(|value| !value.is_empty()),
                    constant: fields[0] == "K",
                }
            })
            .collect()
    })
}
/// Wie Swift über einzelne UTF-16-Zellen; Surrogate sind absichtlich keine Wortzeichen.
pub fn prefix_range(source: &str, cursor: usize) -> Option<Utf16Range> {
    let units: Vec<_> = source.encode_utf16().collect();
    if cursor == 0 || cursor > units.len() {
        return None;
    }
    let at = |index: usize| units.get(index).and_then(|u| char::from_u32(u32::from(*u)));
    let word = |c| four_d::completion_properties(c) & 3 != 0 || c == '_';
    let mut start = cursor;
    while start > 0 {
        let Some(c) = at(start - 1) else { break };
        if word(c) || c == ' ' && start >= 2 && at(start - 2).is_some_and(word) {
            start -= 1;
        } else {
            break;
        }
    }
    if start == cursor
        || start > 0 && at(start - 1).is_some_and(|c| matches!(c, '$' | '.' | '[' | '>'))
    {
        return None;
    }
    if !at(start).is_some_and(|c| four_d::completion_properties(c) & 1 != 0) {
        return None;
    }
    let range = Utf16Range {
        location: start,
        length: cursor - start,
    };
    range.byte_range(source).ok()?;
    Some(range)
}
fn canonical_prefix(value: &str, needle: &str) -> Result<bool, Error> {
    if !value.starts_with(needle) {
        return Ok(false);
    }
    if value.len() == needle.len() || value.is_ascii() {
        return Ok(true);
    }
    // Swift hasPrefix vergleicht Character: ein Lowercase-i darf i + Punkt nicht anschneiden.
    let mut end = 0;
    for part in icu::graphemes(value)? {
        end += part.len();
        if end >= needle.len() {
            return Ok(end == needle.len());
        }
    }
    Ok(false)
}
pub fn matches(
    prefix: &str,
    project: &[Method],
    components: &[Component],
    limit: usize,
    cancel: &Cancellation,
) -> Result<Vec<Candidate>, Error> {
    cancel.check()?;
    if prefix.len() > 4096 || project.len() > 2000 || components.len() > 2000 {
        return Err(Error::Limit);
    }
    let needle = four_d::method_key(prefix);
    let limit = limit.min(MAX_MATCHES);
    if needle.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    let mut result = Vec::new();
    for symbol in symbols().iter().filter(|s| !s.constant) {
        cancel.check()?;
        if canonical_prefix(&symbol.key, &needle)? {
            result.push(Candidate {
                name: symbol.name.into(),
                signature: symbol.signature.map(str::to_owned),
                kind: Kind::Command,
            });
            if result.len() == limit {
                return Ok(result);
            }
        }
    }
    for method in project {
        cancel.check()?;
        if canonical_prefix(&four_d::method_key(&method.name), &needle)? {
            result.push(Candidate {
                name: method.name.clone(),
                signature: method.signature.clone(),
                kind: Kind::Project,
            });
            if result.len() == limit {
                return Ok(result);
            }
        }
    }
    let project_names: HashSet<_> = project
        .iter()
        .map(|m| four_d::method_key(&m.name))
        .collect();
    for method in components {
        cancel.check()?;
        let key = four_d::method_key(&method.name);
        if canonical_prefix(&key, &needle)? && !project_names.contains(&key) {
            result.push(Candidate {
                name: method.name.clone(),
                signature: method.signature.clone(),
                kind: Kind::Component(method.component.clone()),
            });
            if result.len() == limit {
                return Ok(result);
            }
        }
    }
    for symbol in symbols().iter().filter(|s| s.constant) {
        cancel.check()?;
        if canonical_prefix(&symbol.key, &needle)? {
            result.push(Candidate {
                name: symbol.name.into(),
                signature: None,
                kind: Kind::Constant,
            });
            if result.len() == limit {
                return Ok(result);
            }
        }
    }
    Ok(result)
}
pub fn suggest(
    source: &str,
    selection: Utf16Range,
    manual: bool,
    popup_open: bool,
    project: &[Method],
    components: &[Component],
    cancel: &Cancellation,
) -> Result<Option<Suggestions>, Error> {
    cancel.check()?;
    if source.len() > four_d::MAX_SOURCE_BYTES {
        return Err(Error::Limit);
    }
    if selection.length != 0 {
        return Ok(None);
    }
    let Some(range) = prefix_range(source, selection.location) else {
        return Ok(None);
    };
    if range.length
        < if manual || popup_open {
            1
        } else {
            AUTOMATIC_MINIMUM
        }
    {
        return Ok(None);
    }
    let bytes = range.byte_range(source)?;
    if !four_d::completion_range_is_code(source, bytes.clone(), cancel).map_err(|e| match e {
        four_d::Error::Cancelled => Error::Cancelled,
        _ => Error::InvalidRange,
    })? {
        return Ok(None);
    }
    let items = matches(&source[bytes], project, components, MAX_MATCHES, cancel)?;
    Ok((!items.is_empty()).then_some(Suggestions { range, items }))
}
