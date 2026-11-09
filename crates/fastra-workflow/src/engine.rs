use crate::{Definition, Error, Workflow};
use fastra_core::{
    text_operations::{
        self, CharacterOperation as C, DuplicateMode as D, IndentOptions, LineOperation as L,
        RootSortOptions,
    },
    Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest, Utf16Range,
};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use unicode_segmentation::UnicodeSegmentation;
#[derive(Debug)]
pub struct StepPreview {
    pub index: usize,
    pub kind: String,
    pub before: Arc<str>,
    pub after: Arc<str>,
    pub matches: Option<usize>,
}
pub struct Preview {
    source: Arc<str>,
    output: Arc<str>,
    revision: u64,
    generation: u64,
    definition: Workflow,
    selection: Option<Utf16Range>,
    locale: Option<Box<text_operations::TitlecaseLocale>>,
    pub steps: Vec<StepPreview>,
}
impl Preview {
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn locale(&self) -> Option<&text_operations::TitlecaseLocale> {
        self.locale.as_deref()
    }
    pub fn output(&self) -> &str {
        &self.output
    }
    pub fn apply(
        &self,
        current: &str,
        revision: u64,
        generation: u64,
        definition: &Workflow,
        selection: Option<Utf16Range>,
        cancel: &Cancellation,
    ) -> Result<&str, Error> {
        self.apply_with_locale(
            current, revision, generation, definition, selection, None, cancel,
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub fn apply_with_locale(
        &self,
        current: &str,
        revision: u64,
        generation: u64,
        definition: &Workflow,
        selection: Option<Utf16Range>,
        locale: Option<&text_operations::TitlecaseLocale>,
        cancel: &Cancellation,
    ) -> Result<&str, Error> {
        cancel.check()?;
        if locale != self.locale.as_deref() {
            return Err(Error::Stale);
        }
        if current != self.source.as_ref()
            || revision != self.revision
            || generation != self.generation
            || definition != &self.definition
            || selection != self.selection
        {
            return Err(Error::Stale);
        }
        Ok(&self.output)
    }
}
fn check(cancel: &Cancellation, start: Instant) -> Result<(), Error> {
    cancel.check()?;
    if start.elapsed() > Duration::from_secs(5) {
        return Err(Error::Limit);
    }
    Ok(())
}
fn transform(
    text: &str,
    step: &crate::Step,
    locale: Option<&text_operations::TitlecaseLocale>,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<(String, Option<usize>), Error> {
    if matches!(
        step.kind.as_str(),
        "keepLinesMatching" | "deleteLinesMatching"
    ) && step.argument.is_empty()
    {
        return Err(Error::Invalid("empty line regex".into()));
    }
    let zero = Utf16Range {
        location: 0,
        length: 0,
    };
    if matches!(step.kind.as_str(), "sortAscending" | "sortDescending") {
        if let Some(locale) = locale {
            let output = text_operations::sort_lines_with_locale(
                text, zero, step.kind == "sortDescending", locale, limits, cancel,
            )?.map_or_else(|| text.into(), |result| result.text);
            return Ok((preserve_endings(text, &output, cancel)?, None));
        }
    }
    let lines = match step.kind.as_str() {
        "detab" => Some(L::Detab {
            tab_width: step.tab_width,
        }),
        "entab" => Some(L::Entab {
            tab_width: step.tab_width,
        }),
        "shiftRight" | "shiftLeft" => {
            let profile = IndentOptions {
                uses_tabs: step.uses_tabs,
                indent_width: step.indent_width,
                tab_width: step.tab_width,
            };
            Some(if step.kind == "shiftRight" {
                L::ShiftRight(profile)
            } else {
                L::ShiftLeft(profile)
            })
        }
        "hardWrap" => Some(L::HardWrap {
            column: step.wrap_column,
        }),
        "sortAscending" => Some(L::SortRoot(RootSortOptions::default())),
        "sortDescending" => Some(L::SortRoot(RootSortOptions {
            descending: true,
            ..RootSortOptions::default()
        })),
        "removeDuplicateLines" => Some(L::Duplicates(D::KeepFirst)),
        "keepDuplicateLines" => Some(L::Duplicates(D::KeepDuplicates)),
        "removeAllDuplicatedLines" => Some(L::Duplicates(D::RemoveAllDuplicates)),
        "reverseLines" => Some(L::Reverse),
        "removeBlankLines" => Some(L::RemoveBlank),
        "trimTrailing" => Some(L::TrimTrailingWhitespace),
        "prefixLines" => Some(L::Prefix(step.argument.clone())),
        "suffixLines" => Some(L::Suffix(step.argument.clone())),
        "joinLines" => Some(L::Join(" ".into())),
        "joinLinesTight" => Some(L::Join(String::new())),
        "addLineNumbers" => Some(L::AddNumbers),
        "removeLineNumbers" => Some(L::RemoveNumbers),
        "keepLinesMatching" | "deleteLinesMatching" => Some(L::Filter {
            pattern: step.argument.clone(),
            keep_matching: step.kind == "keepLinesMatching",
            case_sensitive: step.case_sensitive,
        }),
        _ => None,
    };
    if let Some(op) = lines {
        let mut output = text_operations::transform_lines(text, zero, &op, limits, cancel)?
            .map_or_else(|| text.into(), |r| r.text);
        if !matches!(op, L::Join(_))
            && !(matches!(op, L::Prefix(_) | L::Suffix(_))
                && step
                    .argument
                    .contains(['\r', '\n', '\u{85}', '\u{2028}', '\u{2029}']))
        {
            output = preserve_endings(text, &output, cancel)?;
        }
        return Ok((output, None));
    }
    if matches!(step.kind.as_str(), "uppercase" | "lowercase") {
        if let Some(locale) = locale {
            return Ok((
                text_operations::case_with_locale(text, zero, step.kind == "uppercase", locale, limits, cancel)?
                    .map_or_else(|| text.into(), |r| r.text),
                None,
            ));
        }
    }
    if step.kind == "titlecase" {
        let locale = locale.ok_or_else(|| Error::Invalid("titlecase locale required".into()))?;
        return Ok((
            text_operations::titlecase_with_locale(text, zero, locale, limits, cancel)?
                .map_or_else(|| text.into(), |r| r.text),
            None,
        ));
    }
    let chars = match step.kind.as_str() {
        "straightenQuotes" => Some(C::StraightenQuotes),
        "educateQuotes" => Some(C::EducateQuotes),
        "convertEscapeSequences" => Some(C::ConvertEscapes),
        "exchangeCharacters" => Some(C::ExchangeCharacters),
        "exchangeWords" => Some(C::ExchangeWords),
        "stripDiacriticals" => Some(C::StripDiacriticals),
        "addEmojiPresentation" => Some(C::AddEmojiPresentation),
        "removeEmojiPresentation" => Some(C::RemoveEmojiPresentation),
        "fourDDetokenize" => Some(C::FourDDetokenize),
        "fourDTokenizeCommands" => Some(C::FourDTokenizeCommands),
        "uppercase" => Some(C::UppercaseRoot),
        "lowercase" => Some(C::LowercaseRoot),
        "normalizeSpaces" => Some(C::NormalizeSpaces),
        "zapGremlins" => Some(C::ZapGremlins),
        "precomposeUnicode" => Some(C::Nfc),
        "decomposeUnicode" => Some(C::Nfd),
        _ => None,
    };
    if let Some(op) = chars {
        return Ok((
            text_operations::transform_characters(text, zero, op, limits, cancel)
                .map_err(|error| {
                    if matches!(
                        step.kind.as_str(),
                        "fourDDetokenize" | "fourDTokenizeCommands"
                    ) && error == fastra_core::Error::InvalidRange
                    {
                        Error::Invalid("4D grapheme token".into())
                    } else {
                        Error::Core(error)
                    }
                })?
                .map_or_else(|| text.into(), |r| r.text),
            None,
        ));
    }
    if step.kind == "replace" {
        if step.find.is_empty() {
            return Err(Error::Invalid("empty find".into()));
        }
        let request = SearchRequest {
            pattern: step.find.clone(),
            replacement: step.replacement.clone(),
            mode: if step.regex {
                SearchMode::Regex
            } else if step.literal_wildcard {
                SearchMode::Literal
            } else {
                SearchMode::Wildcard
            },
            case_sensitive: step.case_sensitive,
            range: None,
        };
        let plan = PreparedSearch::new(
            &request,
            SearchFlags {
                whole_word: step.whole_word,
            },
            limits,
            cancel,
        )?;
        let preview = plan.preview(text, 0, 0)?;
        let matches = preview.matches().len();
        return Ok((
            preview.apply(text, 0, 0, &(0..matches).collect::<Vec<_>>(), cancel)?,
            Some(matches),
        ));
    }
    Err(Error::Unsupported(vec![step.kind.clone()]))
}
#[allow(clippy::too_many_arguments)]
fn preview_inner(
    definition: &Workflow,
    source: &str,
    selection: Option<Utf16Range>,
    revision: u64,
    generation: u64,
    locale: Option<&text_operations::TitlecaseLocale>,
    cancel: &Cancellation,
) -> Result<Preview, Error> {
    let start = Instant::now();
    check(cancel, start)?;
    definition.validate()?;
    let mut unsupported: Vec<_> = definition
        .steps
        .iter()
        .enumerate()
        .filter(|(_, s)| s.enabled && !s.supported())
        .map(|(i, s)| format!("{}: {}", i + 1, s.kind))
        .collect();
    unsupported.extend(
        definition
            .extra
            .keys()
            .map(|key| format!("workflow.{}", key.escape_debug())),
    );
    for (index, step) in definition
        .steps
        .iter()
        .enumerate()
        .filter(|(_, step)| step.enabled)
    {
        unsupported.extend(
            step.extra
                .keys()
                .map(|key| format!("{}.{}", index + 1, key.escape_debug())),
        );
    }
    if !unsupported.is_empty() {
        return Err(Error::Unsupported(unsupported));
    }
    if source.contains('\0') {
        return Err(Error::Unsupported(vec!["source: U+0000".into()]));
    }
    let max = 4 * 1024 * 1024;
    if source.len() > max {
        return Err(Error::Limit);
    }
    let range = match selection {
        Some(range) if range.length > 0 => range.byte_range(source)?,
        Some(_) => return Err(Error::Invalid("empty selection".into())),
        None => 0..source.len(),
    };
    if selection.is_some() {
        let mut start_ok = range.start == source.len();
        let mut end_ok = range.end == source.len();
        for (index, (offset, _)) in source.grapheme_indices(true).enumerate() {
            if index % 2048 == 0 {
                check(cancel, start)?;
            }
            start_ok |= offset == range.start;
            end_ok |= offset == range.end;
            if start_ok && end_ok {
                break;
            }
        }
        if !start_ok || !end_ok {
            return Err(Error::Invalid("grapheme selection".into()));
        }
    }
    let limits = Limits {
        max_text_bytes: max,
        max_output_bytes: max,
        ..Limits::default()
    };
    let mut working: Arc<str> = source[range.clone()].into();
    let mut retained = source.len() + range.len();
    let mut steps = Vec::new();
    for (index, step) in definition
        .steps
        .iter()
        .enumerate()
        .filter(|(_, s)| s.enabled)
    {
        check(cancel, start)?;
        let (output, matches) = transform(&working, step, locale, limits, cancel)?;
        if output.contains('\0') {
            return Err(Error::Unsupported(vec![format!(
                "{}.output: U+0000",
                index + 1
            )]));
        }
        check(cancel, start)?;
        retained = retained.checked_add(output.len()).ok_or(Error::Limit)?;
        if retained > 32 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        let after: Arc<str> = output.into();
        steps.push(StepPreview {
            index,
            kind: step.kind.clone(),
            before: working,
            after: after.clone(),
            matches,
        });
        working = after;
    }
    if source.len() - range.len() + working.len() > max
        || retained + source.len() - range.len() + working.len() > 32 * 1024 * 1024
    {
        return Err(Error::Limit);
    }
    let mut output = String::with_capacity(source.len() - range.len() + working.len());
    output.push_str(&source[..range.start]);
    output.push_str(&working);
    output.push_str(&source[range.end..]);
    if output.contains('\0') {
        return Err(Error::Unsupported(vec!["output: U+0000".into()]));
    }
    check(cancel, start)?;
    Ok(Preview {
        source: source.into(),
        output: output.into(),
        revision,
        generation,
        definition: definition.clone(),
        selection,
        locale: locale.cloned().map(Box::new),
        steps,
    })
}

fn content_lines(text: &str) -> Vec<(&str, &str)> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut iter = text.char_indices().peekable();
    while let Some((at, c)) = iter.next() {
        if matches!(c, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            let mut end = at + c.len_utf8();
            if c == '\r' && iter.peek().is_some_and(|(_, c)| *c == '\n') {
                let (at, c) = iter.next().unwrap();
                end = at + c.len_utf8();
            }
            result.push((&text[start..at], &text[at..end]));
            start = end;
        }
    }
    if start < text.len() {
        result.push((&text[start..], ""));
    }
    result
}
fn preserve_endings(before: &str, after: &str, cancel: &Cancellation) -> Result<String, Error> {
    let before = content_lines(before);
    let after_lines = content_lines(after);
    if before.len() != after_lines.len() {
        return Ok(after.into());
    }
    let mut output = String::new();
    for ((_, ending), (line, _)) in before.into_iter().zip(after_lines) {
        cancel.check()?;
        output.push_str(line);
        output.push_str(ending);
    }
    Ok(output)
}

/// Die Zeitgrenze unterbricht auch lange einzelne Core-Operationen über deren
/// bestehende Abbruchprüfungen; Fehler liefern niemals eine Teilvorschau.
pub fn preview(
    definition: &Workflow,
    source: &str,
    selection: Option<Utf16Range>,
    revision: u64,
    generation: u64,
    cancel: &Cancellation,
) -> Result<Preview, Error> {
    preview_with_locale(
        definition, source, selection, revision, generation, None, cancel,
    )
}
/// Ohne Locale bleiben Groß-/Kleinschreibung und Sortierung deterministisch Root.
/// Produkt-Hosts erfassen für `Step::uses_text_locale()` ausdrücklich ihren Snapshot.
#[allow(clippy::too_many_arguments)]
pub fn preview_with_locale(
    definition: &Workflow,
    source: &str,
    selection: Option<Utf16Range>,
    revision: u64,
    generation: u64,
    locale: Option<&text_operations::TitlecaseLocale>,
    cancel: &Cancellation,
) -> Result<Preview, Error> {
    use std::sync::atomic::{AtomicBool, Ordering};
    let done = AtomicBool::new(false);
    let child = Cancellation::default();
    let start = Instant::now();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !done.load(Ordering::Relaxed) {
                if cancel.check().is_err() || start.elapsed() > Duration::from_secs(5) {
                    child.cancel();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        let result = preview_inner(
            definition, source, selection, revision, generation, locale, &child,
        );
        done.store(true, Ordering::Relaxed);
        cancel.check()?;
        if start.elapsed() > Duration::from_secs(5) {
            Err(Error::Limit)
        } else {
            result
        }
    })
}
