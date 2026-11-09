use super::*;
#[derive(Debug)]
struct Reference {
    range: Range<usize>,
    number: usize,
}
fn scan(text: &str, count: usize) -> Vec<Reference> {
    let budget = crate::wildcard::reference_digits(count);
    let mut references = vec![];
    let mut at = 0;
    while at < text.len() {
        let c = text[at..].chars().next().unwrap();
        let start = at;
        at += c.len_utf8();
        if c == '\\' {
            if let Some(next) = text[at..].chars().next() {
                at += next.len_utf8();
            }
        } else if c == '$' && text.as_bytes().get(at).is_some_and(u8::is_ascii_digit) {
            let mut number = 0;
            for _ in 0..budget {
                let Some(&digit) = text.as_bytes().get(at).filter(|b| b.is_ascii_digit()) else {
                    break;
                };
                number = number * 10 + usize::from(digit - b'0');
                at += 1;
            }
            references.push(Reference {
                range: start..at,
                number,
            });
        }
    }
    references
}
pub(super) fn references(text: &str, number: usize, count: usize) -> bool {
    scan(text, count).iter().any(|r| r.number == number)
}
#[derive(Debug, PartialEq, Eq)]
enum Reading {
    Literal(String),
    Group(usize),
}
fn literal(parts: &mut Vec<Reading>, text: &str) {
    if text.is_empty() {
        return;
    }
    if let Some(Reading::Literal(previous)) = parts.last_mut() {
        previous.push_str(text);
    } else {
        parts.push(Reading::Literal(text.into()));
    }
}
fn reading(text: &str, count: usize, mapping: impl Fn(usize) -> usize) -> Vec<Reading> {
    let mut result = vec![];
    let mut at = 0;
    for r in scan(text, count) {
        literal(&mut result, &text[at..r.range.start]);
        at = r.range.end;
        if r.number <= count {
            result.push(Reading::Group(mapping(r.number)));
        }
    }
    literal(&mut result, &text[at..]);
    result
}
pub(super) fn rewrite(
    text: &str,
    count: usize,
    new_count: usize,
    mapping: impl Fn(usize) -> usize + Copy,
) -> Option<String> {
    let mut result = String::new();
    let mut at = 0;
    let budget = crate::wildcard::reference_digits(new_count);
    for r in scan(text, count) {
        result.push_str(&text[at..r.range.start]);
        at = r.range.end;
        let target = if r.number <= count {
            mapping(r.number)
        } else if r.number <= new_count && (new_count + 1).to_string().len() <= budget {
            new_count + 1
        } else {
            r.number
        };
        let plain = target.to_string();
        let mut width = if target == r.number {
            r.range.len() - 1
        } else {
            plain.len()
        };
        if width > budget {
            width = plain.len().max(budget);
        }
        if text.as_bytes().get(at).is_some_and(u8::is_ascii_digit) {
            width = width.max(budget);
        }
        result.push('$');
        result.push_str(&"0".repeat(width.saturating_sub(plain.len())));
        result.push_str(&plain);
    }
    result.push_str(&text[at..]);
    (reading(text, count, mapping) == reading(&result, new_count, |n| n)).then_some(result)
}
