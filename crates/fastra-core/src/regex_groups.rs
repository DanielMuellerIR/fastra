//! Geführte Gruppenbearbeitung mit derselben Syntaxbasis und Einheitenregel wie auf dem Mac.
use crate::{icu, Cancellation, Error, Limits, Utf16Range};
use std::ops::Range;
mod references;
mod syntax;
pub use syntax::{tokenize, Group, Kind, Syntax, Token};
#[cfg(test)]
mod tests;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unit {
    pub pattern_range: Range<usize>,
    pub match_range: Option<Utf16Range>,
    pub existing_group: Option<usize>,
    pub zero_width: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub snapped_match_range: Utf16Range,
    pub pattern: String,
    pub group_number: usize,
    pub replacement: String,
    pub already_group: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Removal {
    pub pattern: String,
    pub replacement: String,
}
fn raw_units(pattern: &str, syntax: &Syntax) -> Option<Vec<Unit>> {
    if syntax.has_errors || syntax.source != pattern {
        return None;
    }
    let mut depth = 0;
    for token in &syntax.tokens {
        let text = pattern.get(token.range.clone())?;
        if token.kind == Kind::Delimiter {
            if text.starts_with('(') {
                depth += 1;
            } else if text == ")" {
                depth -= 1;
            }
        } else if token.kind == Kind::Alternation && depth == 0 {
            return Some(vec![Unit {
                pattern_range: 0..pattern.len(),
                match_range: None,
                existing_group: None,
                zero_width: false,
            }]);
        }
    }
    let mut result = vec![];
    let mut at = 0;
    while at < syntax.tokens.len() {
        let token = &syntax.tokens[at];
        let mut range = token.range.clone();
        let mut existing = None;
        let zero = token.kind == Kind::Anchor;
        if token.kind == Kind::Delimiter && pattern.get(range.clone())?.starts_with('(') {
            let start = at;
            let mut depth = 1;
            at += 1;
            while at < syntax.tokens.len() && depth > 0 {
                let t = &syntax.tokens[at];
                let text = pattern.get(t.range.clone())?;
                if t.kind == Kind::Delimiter {
                    if text.starts_with('(') {
                        depth += 1;
                    } else if text == ")" {
                        depth -= 1;
                    }
                }
                at += 1;
            }
            if depth != 0 {
                return None;
            }
            range = syntax.tokens[start].range.start..syntax.tokens[at - 1].range.end;
            existing = syntax
                .groups
                .iter()
                .find(|g| g.range == range)
                .map(|g| g.number);
        } else {
            at += 1;
        }
        if let Some(quant) = syntax.tokens.get(at).filter(|t| t.kind == Kind::Quantifier) {
            if token.kind == Kind::Literal {
                let text = pattern.get(range.clone())?;
                let graphemes = icu::graphemes(text).ok()?;
                let last = graphemes.last()?;
                let split = range.end - last.len();
                if split > range.start {
                    result.push(Unit {
                        pattern_range: range.start..split,
                        match_range: None,
                        existing_group: None,
                        zero_width: false,
                    });
                    range.start = split;
                }
            }
            range.end = quant.range.end;
            existing = None;
            at += 1;
        }
        let zero = zero || syntax.unscoped_flags.contains(&range);
        result.push(Unit {
            pattern_range: range,
            match_range: None,
            existing_group: existing,
            zero_width: zero,
        });
    }
    Some(result)
}
fn known_count(
    pattern: &str,
    syntax: &Syntax,
    case_sensitive: bool,
    cancel: &Cancellation,
) -> Result<bool, Error> {
    match icu::Regex::new(pattern, "", case_sensitive, Limits::default(), cancel) {
        Ok(regex) => Ok(regex.group_count() == syntax.groups.len()),
        Err(Error::Regex { .. }) => Ok(false),
        Err(e) => Err(e),
    }
}
pub fn units(
    pattern: &str,
    syntax: &Syntax,
    match_text: &str,
    case_sensitive: bool,
    cancel: &Cancellation,
) -> Result<Option<Vec<Unit>>, Error> {
    cancel.check()?;
    if pattern.len() > 65536 || match_text.len() > 65536 {
        return Err(Error::Limit);
    }
    if !known_count(pattern, syntax, case_sensitive, cancel)? {
        return Ok(None);
    }
    let Some(mut units) = raw_units(pattern, syntax) else {
        return Ok(None);
    };
    let mut instrument = String::from("\\A(?s:");
    let mut numbers = vec![];
    let mut count = 0;
    for unit in &units {
        let snippet = &pattern[unit.pattern_range.clone()];
        if unit.zero_width {
            instrument.push_str(snippet);
            numbers.push(None);
            continue;
        }
        numbers.push(Some(count + 1));
        cancel.check()?;
        let nested = syntax
            .groups
            .partition_point(|g| g.range.start < unit.pattern_range.end)
            - syntax
                .groups
                .partition_point(|g| g.range.start < unit.pattern_range.start);
        if unit.existing_group.is_some() {
            instrument.push_str(snippet);
            count += nested;
        } else {
            instrument.push('(');
            instrument.push_str(snippet);
            instrument.push(')');
            count += 1 + nested;
        }
    }
    instrument.push_str(")\\z");
    let mut regex = match icu::Regex::new(
        &instrument,
        match_text,
        case_sensitive,
        Limits::default(),
        cancel,
    ) {
        Ok(regex) => regex,
        Err(Error::Regex { .. }) => return Ok(None),
        Err(e) => return Err(e),
    };
    let Some(captures) = regex.next()? else {
        return Ok(None);
    };
    for (unit, number) in units.iter_mut().zip(numbers) {
        unit.match_range = number
            .and_then(|n| captures.get(n).copied().flatten())
            .filter(|r| r.length > 0);
    }
    Ok(Some(units))
}
pub fn propose(
    selection: Utf16Range,
    pattern: &str,
    syntax: &Syntax,
    match_text: &str,
    replacement: &str,
    case_sensitive: bool,
    cancel: &Cancellation,
) -> Result<Option<Proposal>, Error> {
    cancel.check()?;
    if syntax.tokens.iter().any(|t| t.kind == Kind::Backreference) {
        return Ok(None);
    }
    if selection.end()? > match_text.encode_utf16().count() {
        return Err(Error::InvalidRange);
    }
    let Some(units) = units(pattern, syntax, match_text, case_sensitive, cancel)? else {
        return Ok(None);
    };
    let end = selection.end()?;
    let hits = units
        .iter()
        .enumerate()
        .filter_map(|(i, u)| {
            u.match_range
                .filter(|r| {
                    let stop = r.location + r.length;
                    if selection.length == 0 {
                        r.location <= selection.location && selection.location <= stop
                    } else {
                        r.location < end && selection.location < stop
                    }
                })
                .map(|_| i)
        })
        .collect::<Vec<_>>();
    let Some(&last) = hits.last() else {
        return Ok(None);
    };
    let first = if selection.length == 0 { last } else { hits[0] };
    let spans = units[first..=last]
        .iter()
        .filter_map(|u| u.match_range)
        .collect::<Vec<_>>();
    let lo = spans.iter().map(|r| r.location).min().unwrap();
    let hi = spans.iter().map(|r| r.location + r.length).max().unwrap();
    let snapped_match_range = Utf16Range {
        location: lo,
        length: hi - lo,
    };
    if let Some(number) = units[first].existing_group.filter(|_| first == last) {
        return Ok(Some(Proposal {
            snapped_match_range,
            pattern: pattern.into(),
            replacement: replacement.into(),
            group_number: number,
            already_group: true,
        }));
    }
    let start = units[first].pattern_range.start;
    let end = units[last].pattern_range.end;
    // Eine neue Klammer darf unbeschränkte Flags nicht vorzeitig beenden.
    if end < pattern.len()
        && syntax.unscoped_flags.iter().any(|r| {
            r.start >= start
                && r.end <= end
                && !syntax.groups.iter().any(|g| {
                    g.range.start >= start
                        && g.range.end <= end
                        && g.inner.start <= r.start
                        && r.end <= g.inner.end
                })
        })
    {
        return Ok(None);
    }
    let number = 1 + syntax
        .groups
        .iter()
        .filter(|g| g.range.start < start)
        .count();
    let Some(replacement) = references::rewrite(
        replacement,
        syntax.groups.len(),
        syntax.groups.len() + 1,
        |n| if n >= number { n + 1 } else { n },
    ) else {
        return Ok(None);
    };
    let pattern = format!(
        "{}({}){}",
        &pattern[..start],
        &pattern[start..end],
        &pattern[end..]
    );
    cancel.check()?;
    Ok(Some(Proposal {
        snapped_match_range,
        pattern,
        replacement,
        group_number: number,
        already_group: false,
    }))
}
pub fn remove(
    number: usize,
    pattern: &str,
    syntax: &Syntax,
    replacement: &str,
    cancel: &Cancellation,
) -> Result<Option<Removal>, Error> {
    cancel.check()?;
    if syntax.has_errors
        || syntax.source != pattern
        || !known_count(pattern, syntax, true, cancel)?
        || syntax.tokens.iter().any(|t| t.kind == Kind::Backreference)
    {
        return Ok(None);
    }
    let Some(group) = syntax.groups.iter().find(|g| g.number == number) else {
        return Ok(None);
    };
    if references::references(replacement, number, syntax.groups.len())
        || syntax
            .tokens
            .iter()
            .any(|t| t.kind == Kind::Quantifier && t.range.start == group.range.end)
    {
        return Ok(None);
    }
    // Ohne die entfernte Klammer könnten Flags auf nachfolgenden Text wirken.
    if syntax.unscoped_flags.iter().any(|r| {
        r.start >= group.inner.start
            && r.end <= group.inner.end
            && !syntax.groups.iter().any(|other| {
                other.number != number
                    && other.range.start >= group.inner.start
                    && other.range.end <= group.inner.end
                    && other.inner.start <= r.start
                    && r.end <= other.inner.end
            })
    }) {
        return Ok(None);
    }
    let alternation = syntax.tokens.iter().any(|t| {
        t.kind == Kind::Alternation
            && group.inner.contains(&t.range.start)
            && !syntax.groups.iter().any(|other| {
                other.number != number
                    && other.range.start >= group.inner.start
                    && other.range.end <= group.inner.end
                    && other.range.contains(&t.range.start)
            })
    });
    if alternation {
        return Ok(None);
    }
    let Some(replacement) = references::rewrite(
        replacement,
        syntax.groups.len(),
        syntax.groups.len().saturating_sub(1),
        |n| if n > number { n - 1 } else { n },
    ) else {
        return Ok(None);
    };
    Ok(Some(Removal {
        pattern: format!(
            "{}{}{}",
            &pattern[..group.range.start],
            &pattern[group.inner.clone()],
            &pattern[group.range.end..]
        ),
        replacement,
    }))
}
