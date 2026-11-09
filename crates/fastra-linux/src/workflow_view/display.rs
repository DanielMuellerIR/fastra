use super::*;
use std::{collections::HashMap, sync::Arc};
const DISPLAY_BYTES: usize = 64 * 1024 * 1024;
fn rendered<'a>(
    text: &'a str,
    cache: &mut HashMap<&'a str, Arc<str>>,
    bytes: &mut usize,
    lang: Language,
    cancel: &Cancellation,
) -> Result<Arc<str>, Error> {
    if let Some(text) = cache.get(text) {
        return Ok(text.clone());
    }
    let display = fastra_core::display::escaped_text(text, cancel, DISPLAY_BYTES - *bytes)?;
    crate::text_limits::validate(&display, lang).map_err(Error::Invalid)?;
    *bytes += display.len();
    let display: Arc<str> = display.into();
    cache.insert(text, display.clone());
    Ok(display)
}
pub(super) fn prepare<'a>(
    result: &'a workflow::Preview,
    lang: Language,
    cancel: &Cancellation,
) -> Result<DisplayPlan, Error> {
    let mut cache = HashMap::new();
    let mut bytes = 0;
    let mut pair = |before: &'a str, after: &'a str| -> Result<_, Error> {
        Ok((
            rendered(before, &mut cache, &mut bytes, lang, cancel)?,
            rendered(after, &mut cache, &mut bytes, lang, cancel)?,
        ))
    };
    let mut pairs = Vec::new();
    pairs.push(pair(result.source(), result.output())?);
    for step in &result.steps {
        cancel.check()?;
        pairs.push(pair(&step.before, &step.after)?);
    }
    cancel.check()?;
    Ok(DisplayPlan { pairs })
}

pub(super) fn validate(
    result: &workflow::Preview,
    source: &str,
    lang: Language,
    cancel: &Cancellation,
) -> Result<(), Error> {
    crate::text_limits::validate(source, lang).map_err(Error::Invalid)?;
    crate::text_limits::validate(result.output(), lang).map_err(Error::Invalid)?;
    for step in &result.steps {
        cancel.check()?;
        crate::text_limits::validate(&step.before, lang).map_err(Error::Invalid)?;
        crate::text_limits::validate(&step.after, lang).map_err(Error::Invalid)?;
    }
    Ok(())
}
