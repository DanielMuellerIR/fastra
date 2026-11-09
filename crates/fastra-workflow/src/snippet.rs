use crate::Error;
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;
#[derive(Debug)]
enum Part {
    Literal(String),
    Placeholder(String),
}
#[derive(Debug)]
pub struct Template {
    parts: Vec<Part>,
    pub names: Vec<String>,
}
impl Template {
    pub fn parse(source: &str) -> Result<Self, Error> {
        if source.contains('\0') {
            return Err(Error::Unsupported(vec!["snippet.template: U+0000".into()]));
        }
        if source.len() > 16 * 1024 {
            return Err(Error::Limit);
        }
        let mut parts = Vec::new();
        let mut names = Vec::new();
        let mut remaining = source;
        while let Some(start) = remaining.find("{{") {
            parts.push(Part::Literal(remaining[..start].into()));
            remaining = &remaining[start + 2..];
            let end = remaining
                .find("}}")
                .ok_or_else(|| Error::Invalid("{{Name}}".into()))?;
            let name = remaining[..end].trim_matches(crate::unicode::horizontal_space);
            if name.is_empty()
                || name.graphemes(true).count() > 64
                || name.chars().any(|c| {
                    c == '{'
                        || c == '}'
                        || crate::unicode::control(c)
                        || matches!(c, '\u{85}' | '\u{2028}' | '\u{2029}')
                })
            {
                return Err(Error::Invalid("{{Name}}".into()));
            }
            if !names.iter().any(|n| n == name) {
                names.push(name.to_string());
            }
            if names.len() > 32 {
                return Err(Error::Limit);
            }
            parts.push(Part::Placeholder(name.into()));
            remaining = &remaining[end + 2..];
        }
        parts.push(Part::Literal(remaining.into()));
        Ok(Self { parts, names })
    }
    pub fn render(&self, values: &BTreeMap<String, String>) -> Result<String, Error> {
        let mut output = String::new();
        for part in &self.parts {
            let text = match part {
                Part::Literal(s) => s,
                Part::Placeholder(name) => {
                    let s = values
                        .get(name)
                        .ok_or_else(|| Error::Missing(name.clone()))?;
                    if s.contains('\0') {
                        return Err(Error::Unsupported(vec![format!("value.{name}: U+0000")]));
                    }
                    if s.len() > 16 * 1024 {
                        return Err(Error::Limit);
                    }
                    s
                }
            };
            if text.len() > 256 * 1024 - output.len() {
                return Err(Error::Limit);
            }
            output.push_str(text);
        }
        Ok(output)
    }
}
