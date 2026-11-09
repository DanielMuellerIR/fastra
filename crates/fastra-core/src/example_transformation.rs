//! Kurze Beispielpaare werden wie im Swift-Bestand zu genau einem Wildcard-Capture.
use crate::{icu, Cancellation, Error};
use unicode_normalization::UnicodeNormalization;

pub const MAX_GRAPHEMES: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inference {
    pub find_pattern: String,
    pub replace_pattern: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    Empty,
    Equal,
    Wildcard,
    TooLong,
    NoCommonPart,
    Core(Error),
}
impl From<Error> for Refusal {
    fn from(value: Error) -> Self {
        Self::Core(value)
    }
}
fn characters<'a>(text: &'a str, cancel: &Cancellation) -> Result<Vec<&'a str>, Refusal> {
    let mut result = Vec::new();
    icu::walk_graphemes(text, |part| {
        cancel.check()?;
        if result.len() == MAX_GRAPHEMES {
            return Err(Error::Limit);
        }
        result.push(part);
        Ok(())
    })
    .map_err(|error| {
        if error == Error::Limit {
            Refusal::TooLong
        } else {
            error.into()
        }
    })?;
    Ok(result)
}
fn key(text: &str) -> String {
    text.nfc().collect()
}

pub fn infer(source: &str, destination: &str, cancel: &Cancellation) -> Result<Inference, Refusal> {
    cancel.check()?;
    if source.is_empty() || destination.is_empty() {
        return Err(Refusal::Empty);
    }
    if source == destination {
        return Err(Refusal::Equal);
    }
    if source.contains('*') || destination.contains('*') {
        return Err(Refusal::Wildcard);
    }
    // Auch ein einzelnes Graphem kann beliebig viele kombinierende Zeichen enthalten.
    let bytes = crate::Limits::interactive_text_operations().max_text_bytes;
    if source.len() > bytes || destination.len() > bytes {
        return Err(Refusal::TooLong);
    }
    let source_chars = characters(source, cancel)?;
    let destination_chars = characters(destination, cancel)?;
    let source_keys: Vec<_> = source_chars.iter().map(|s| key(s)).collect();
    let destination_keys: Vec<_> = destination_chars.iter().map(|s| key(s)).collect();
    if source_keys == destination_keys {
        return Err(Refusal::Equal);
    }
    let mut previous = vec![0; destination_chars.len() + 1];
    let mut best_length = 0;
    let mut best_source_end = 0;
    for (i, a) in source_keys.iter().enumerate() {
        cancel.check()?;
        let mut current = vec![0; previous.len()];
        for (j, b) in destination_keys.iter().enumerate() {
            if a == b {
                current[j + 1] = previous[j] + 1;
                // Nur strikt länger: derselbe Tie-Break wie die Swift-Matrix.
                if current[j + 1] > best_length {
                    best_length = current[j + 1];
                    best_source_end = i + 1;
                }
            }
        }
        previous = current;
    }
    if best_length == 0 {
        return Err(Refusal::NoCommonPart);
    }
    let capture = &source_keys[best_source_end - best_length..best_source_end];
    let first_range = |keys: &[String]| {
        keys.windows(best_length)
            .position(|candidate| candidate == capture)
    };
    let source_start = first_range(&source_keys).ok_or(Refusal::NoCommonPart)?;
    let destination_start = first_range(&destination_keys).ok_or(Refusal::NoCommonPart)?;
    let surround = |parts: &[&str], start: usize| {
        format!(
            "{}*{}",
            parts[..start].concat(),
            parts[start + best_length..].concat()
        )
    };
    Ok(Inference {
        find_pattern: surround(&source_chars, source_start),
        replace_pattern: surround(&destination_chars, destination_start),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExamplePreview {
    pub text: String,
    pub reproduces_destination: bool,
}
impl Inference {
    /// Nutzt die echte Wildcard-Engine; das Formular wird dadurch nicht verändert.
    pub fn preview(
        &self,
        source: &str,
        destination: &str,
        cancel: &Cancellation,
    ) -> Result<ExamplePreview, Error> {
        let request = crate::SearchRequest {
            pattern: self.find_pattern.clone(),
            replacement: self.replace_pattern.clone(),
            mode: crate::SearchMode::Wildcard,
            case_sensitive: true,
            range: None,
        };
        let preview = crate::preview(
            source,
            0,
            0,
            &request,
            crate::Limits::interactive_text_operations(),
            cancel,
        )?;
        let text = preview.apply(
            source,
            0,
            0,
            &(0..preview.matches().len()).collect::<Vec<_>>(),
            cancel,
        )?;
        cancel.check()?;
        let reproduces_destination = key(&text) == key(destination);
        Ok(ExamplePreview {
            text,
            reproduces_destination,
        })
    }
}
