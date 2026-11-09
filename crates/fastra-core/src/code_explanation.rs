//! Gespeicherte Codefragen: Manifest und Graphemgrenzen, ohne Dateizugriff oder Ausführung.
use crate::{icu, Cancellation};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

pub const MAX_MANIFEST_BYTES: usize = 65_536;
pub const MAX_SOURCE_BYTES: usize = 262_144;
pub const MAX_TOTAL_BYTES: usize = 1_048_576;

#[derive(Debug)]
pub enum Error {
    Invalid(&'static str),
    Core(crate::Error),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
impl From<crate::Error> for Error {
    fn from(value: crate::Error) -> Self {
        Self::Core(value)
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct Id(String);
impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).ok_or_else(|| serde::de::Error::custom("invalid UUID"))
    }
}
impl Id {
    pub fn parse(value: &str) -> Option<Self> {
        // Foundation UUID interpretiert nur den Teil vor einem Nullabschluss.
        let value = value.split('\0').next()?;
        (value.len() == 36
            && value.bytes().enumerate().all(|(i, c)| {
                if [8, 13, 18, 23].contains(&i) {
                    c == b'-'
                } else {
                    c.is_ascii_hexdigit()
                }
            }))
        .then(|| Self(value.to_ascii_uppercase()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub id: Id,
    pub path: String,
    pub sha256: String,
    pub encoding: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Step {
    pub id: Id,
    pub title: String,
    pub text: String,
    #[serde(rename = "sourceID")]
    pub source_id: Id,
    #[serde(deserialize_with = "crate::json_integer::usize")]
    pub location: usize,
    #[serde(deserialize_with = "crate::json_integer::usize")]
    pub length: usize,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    #[serde(deserialize_with = "crate::json_integer::i64")]
    pub schema_version: i64,
    pub id: Id,
    pub title: String,
    pub question: String,
    pub language: String,
    pub created_at: String,
    #[serde(rename = "projectID")]
    pub project_id: Id,
    pub project_name: String,
    pub sources: Vec<Source>,
    pub steps: Vec<Step>,
    pub code_font_size: f64,
    pub explanation_font_size: f64,
}
fn text(value: &str, maximum: usize, cancel: &Cancellation) -> Result<(), Error> {
    if value.is_empty() {
        return Err(Error::Invalid("empty text"));
    }
    let mut count = 0;
    icu::walk_graphemes(value, |_| {
        cancel.check()?;
        count += 1;
        if count > maximum {
            Err(crate::Error::Limit)
        } else {
            Ok(())
        }
    })?;
    Ok(())
}
pub fn valid_relative_path(path: &str) -> bool {
    !path.contains('\0')
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}
unsafe extern "C" {
    fn fastra_scalar_decimal_digit(scalar: i32) -> i32;
}
fn digit(c: char) -> Option<u32> {
    let digit = unsafe { fastra_scalar_decimal_digit(c as i32) };
    (digit >= 0).then_some(digit as u32)
}
fn number(
    chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
    minimum: usize,
    maximum: usize,
) -> Option<u32> {
    let mut value = 0;
    let mut count = 0;
    while count < maximum {
        let Some(digit) = chars.peek().copied().and_then(digit) else {
            break;
        };
        chars.next();
        value = value * 10 + digit;
        count += 1;
    }
    (count >= minimum).then_some(value)
}
// ISO8601DateFormatter ist absichtlich nicht strikt: Datumsüberläufe und Text nach der Zone sind zulässig.
pub fn valid_created_at(value: &str) -> bool {
    let mut chars = value.trim_start().chars().peekable();
    let parsed = (|| {
        number(&mut chars, 1, 6)?;
        if chars.next()? != '-' {
            return None;
        }
        let month = number(&mut chars, 1, 2)?;
        if chars.next()? != '-' {
            return None;
        }
        let day = number(&mut chars, 1, 2)?;
        if chars.next()? != 'T' {
            return None;
        }
        let hour = number(&mut chars, 1, 2)?;
        if chars.next()? != ':' {
            return None;
        }
        let minute = number(&mut chars, 1, 2)?;
        if chars.next()? != ':' {
            return None;
        }
        let second = number(&mut chars, 1, 2)?;
        if !(1..=12).contains(&month)
            || !(1..=31).contains(&day)
            || hour > 24
            || minute > 59
            || second > 59
        {
            return None;
        }
        match chars.next()? {
            'Z' => Some(()),
            '+' | '-' => {
                number(&mut chars, 1, 2)?;
                if chars.peek() == Some(&':') {
                    chars.next();
                    number(&mut chars, 1, 2)?;
                } else {
                    number(&mut chars, 0, 2)?;
                }
                Some(())
            }
            _ => None,
        }
    })();
    parsed.is_some()
}
impl Manifest {
    pub fn validate(&self, cancel: &Cancellation) -> Result<(), Error> {
        cancel.check()?;
        if self.schema_version != 1
            || !["de", "en"].contains(&self.language.as_str())
            || !valid_created_at(&self.created_at)
            || !(8.0..=32.0).contains(&self.code_font_size)
            || !(8.0..=32.0).contains(&self.explanation_font_size)
            || !(1..=5).contains(&self.sources.len())
            || !(2..=5).contains(&self.steps.len())
        {
            return Err(Error::Invalid("manifest"));
        }
        text(&self.title, 200, cancel)?;
        text(&self.question, 2000, cancel)?;
        text(&self.project_name, 200, cancel)?;
        let mut sources = HashSet::new();
        for source in &self.sources {
            if !sources.insert(&source.id)
                || source.encoding != "utf8"
                || !valid_relative_path(&source.path)
                || source.sha256.len() != 64
                || !source
                    .sha256
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            {
                return Err(Error::Invalid("source"));
            }
        }
        let mut steps = HashSet::new();
        for step in &self.steps {
            if !steps.insert(&step.id) || !sources.contains(&step.source_id) {
                return Err(Error::Invalid("step source or ID"));
            }
            text(&step.title, 200, cancel)?;
            text(&step.text, 4096, cancel)?;
        }
        Ok(())
    }
}
pub fn validate_range(
    text: &str,
    location: usize,
    length: usize,
    cancel: &Cancellation,
) -> Result<(), Error> {
    cancel.check()?;
    let end = location
        .checked_add(length)
        .ok_or(Error::Invalid("range overflow"))?;
    let mut offset = 0;
    let mut start_boundary = location == 0;
    let mut end_boundary = end == 0;
    icu::walk_graphemes(text, |part| {
        cancel.check()?;
        offset += part.encode_utf16().count();
        start_boundary |= offset == location;
        end_boundary |= offset == end;
        Ok(())
    })?;
    if start_boundary && end_boundary && end <= offset {
        Ok(())
    } else {
        Err(Error::Invalid("grapheme range"))
    }
}
