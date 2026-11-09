//! Begrenzte Mac-Math-Analyse. Die Parseransicht besitzt eigene Bytes; die
//! Dokumentquelle bleibt unverändert und jedes erzeugte Token ist registriert.
use super::parser_view::{source_index, Check, Index, Kind, View};
pub use super::parser_view::{Budget, Error, SourceRange};
use fastra_core::{Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest};
use std::{
    collections::{BTreeMap, HashMap},
    ops::Range,
};

const FENCE: &str = r"(?ms)(^|\n)([ \t]{0,3})(`{3,}|~{3,})[^\n]*\n.*?\n[ \t]{0,3}\3[ \t]*(?=\n|$)";
const CODE: &str = r"`+[^`\n]*`+";
const BLOCK: &str = r"(?ms)^[ \t]*\$\$[ \t]*(?:\n)?(.+?)(?:\n)?[ \t]*\$\$[ \t]*$";
const DOUBLE: &str = r"(?<!\\)\$\$(?!\s)(.+?)(?<!\s)\$\$";
const SINGLE: &str = r"(?<![\\$])\$(?![\s$])([^$\n]+?)(?<![\s$])\$(?!\$)";
const FENCE_OPEN: &str = r"(?m)^[ \t]{0,3}(`{3,}+|~{3,}+)";
const FENCE_CLOSE: &str = r"(?m)\n[ \t]{0,3}(`{3,}+|~{3,}+)[ \t]*+(?=\n|$)";
const BLOCK_OPEN: &str = r"(?m)^[ \t]*+\$\$";
const BLOCK_CLOSE: &str = r"(?m)\$\$[ \t]*+$";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Formula {
    pub source: SourceRange,
    pub content: SourceRange,
    /// Wie beim Mac in diesem Verarbeitungsschritt erfasster, getrimmter Text.
    /// Enthaltene registrierte Code-/Mathtoken werden ausdrücklich gekennzeichnet.
    pub captured_tex: String,
    pub nested_tokens: bool,
    pub block: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    /// Ausschließlich diese UTF8-Position in prepared() ist ein erzeugtes Token.
    pub prepared: Range<usize>,
    pub formula: usize,
}
#[derive(Clone, Debug)]
struct Hit {
    range: Range<usize>,
    content: Range<usize>,
}
struct Engine {
    budget: Budget,
    cancel: Cancellation,
}
impl Engine {
    fn prepare(&self, pattern: &str) -> Result<PreparedSearch, Error> {
        Ok(PreparedSearch::new(
            &SearchRequest {
                pattern: pattern.into(),
                replacement: String::new(),
                mode: SearchMode::Regex,
                case_sensitive: true,
                range: None,
            },
            SearchFlags::default(),
            Limits {
                max_text_bytes: self.budget.view_bytes,
                max_output_bytes: self.budget.view_bytes,
                max_matches: self.budget.matches,
                regex_time_ms: self.budget.regex_ms,
                ..Limits::default()
            },
            &self.cancel,
        )?)
    }
    fn scan(&self, pattern: &str, source: &str, check: &mut Check<'_>) -> Result<Vec<Hit>, Error> {
        check.now()?;
        let prepared = self.prepare(pattern)?;
        self.scan_prepared(&prepared, source, check)
    }
    fn scan_prepared(
        &self,
        prepared: &PreparedSearch,
        source: &str,
        check: &mut Check<'_>,
    ) -> Result<Vec<Hit>, Error> {
        check.now()?;
        let preview = prepared.preview(source, 0, 0)?;
        let mut output = Vec::with_capacity(preview.matches().len());
        for hit in preview.matches() {
            check.now()?;
            let r = hit.range.location..hit.range.end()?;
            let content = hit.captures.get(1).and_then(|r| *r).unwrap_or(hit.range);
            output.push(Hit {
                range: r,
                content: content.location..content.end()?,
            });
        }
        Ok(output)
    }
    fn fences(
        &self,
        source: &str,
        index: &Index,
        check: &mut Check<'_>,
    ) -> Result<Vec<Hit>, Error> {
        let mut closings: BTreeMap<u16, BTreeMap<usize, Vec<Range<usize>>>> = BTreeMap::new();
        for hit in self.scan(FENCE_CLOSE, source, check)? {
            let marker = &hit.content;
            let first = *index.units.get(marker.start).ok_or(Error::Boundary)?;
            closings
                .entry(first)
                .or_default()
                .entry(marker.len())
                .or_default()
                .push(hit.range);
        }
        if closings.is_empty() {
            return Ok(Vec::new());
        }
        let newlines = index
            .units
            .iter()
            .enumerate()
            .filter_map(|(at, u)| (*u == 10).then_some(at))
            .collect::<Vec<_>>();
        let mut result = Vec::new();
        let mut consumed = 0;
        for opening in self.scan(FENCE_OPEN, source, check)? {
            check.now()?;
            let raw = opening.range.start;
            let start = if raw > 0 && index.units[raw - 1] == 10 && raw > consumed {
                raw - 1
            } else {
                raw
            };
            if start < consumed {
                continue;
            }
            let marker = opening.content;
            let Some(newline) = newlines.get(newlines.partition_point(|at| *at < marker.end))
            else {
                continue;
            };
            let opening_end = newline + 1;
            let Some(lengths) = closings.get(&index.units[marker.start]) else {
                continue;
            };
            let selected = lengths
                .range(3..=marker.len())
                .rev()
                .find_map(|(_, ranges)| {
                    ranges
                        .get(ranges.partition_point(|r| r.start < opening_end))
                        .cloned()
                });
            if let Some(selected) = selected {
                let range = start..selected.end;
                consumed = range.end;
                result.push(Hit {
                    content: range.clone(),
                    range,
                });
            }
        }
        Ok(result)
    }
    fn double_markers(
        &self,
        source: &str,
        index: &Index,
        opening: bool,
        check: &mut Check<'_>,
    ) -> Result<Vec<Hit>, Error> {
        let whitespace = self.prepare(r"\A\s\z")?;
        let mut cache = HashMap::<char, bool>::new();
        let mut is_space = |value: Option<char>, check: &mut Check<'_>| -> Result<bool, Error> {
            let Some(value) = value else {
                return Ok(false);
            };
            if let Some(result) = cache.get(&value) {
                return Ok(*result);
            }
            let result = !self
                .scan_prepared(&whitespace, &value.to_string(), check)?
                .is_empty();
            cache.insert(value, result);
            Ok(result)
        };
        let mut result = Vec::new();
        // Der Mac-Lookahead erlaubt überlappende $$ in längeren Dollarfolgen.
        // Ein globaler Nullbreiten-Lookahead verbraucht schon ohne Kandidaten
        // ICUs Suchbudget; deshalb nur echte Marker prüfen, Unicode weiter mit ICU.
        for (at, pair) in index.units.windows(2).enumerate() {
            if at % 4096 == 0 {
                check.now()?;
            }
            if pair != [36, 36] {
                continue;
            }
            let byte = index.to_byte[at];
            let previous = source[..byte].chars().next_back();
            let eligible = if opening {
                previous != Some('\\')
                    && !is_space(source[index.to_byte[at + 2]..].chars().next(), check)?
            } else {
                !is_space(previous, check)?
            };
            if eligible {
                if result.len() >= self.budget.matches {
                    return Err(Error::Limit);
                }
                result.push(Hit {
                    range: at..at,
                    content: at..at + 2,
                });
            }
        }
        Ok(result)
    }
    fn bounded(
        &self,
        pattern: &str,
        source: &str,
        index: &Index,
        check: &mut Check<'_>,
    ) -> Result<Vec<Hit>, Error> {
        if pattern == FENCE {
            return self.fences(source, index, check);
        }
        if pattern != BLOCK && pattern != DOUBLE {
            return self.scan(pattern, source, check);
        }
        let double = pattern == DOUBLE;
        let openings = if double {
            self.double_markers(source, index, true, check)?
        } else {
            self.scan(BLOCK_OPEN, source, check)?
        };
        if openings.is_empty() {
            return Ok(Vec::new());
        }
        let closing_hits = if double {
            self.double_markers(source, index, false, check)?
        } else {
            self.scan(BLOCK_CLOSE, source, check)?
        };
        let closings = closing_hits
            .into_iter()
            .map(|h| if double { h.content } else { h.range })
            .collect::<Vec<_>>();
        if closings.is_empty() {
            return Ok(Vec::new());
        }
        let mut lines = vec![0usize; index.units.len() + 1];
        let mut line = 0;
        for (at, u) in index.units.iter().enumerate() {
            if at % 4096 == 0 {
                check.now()?;
            }
            lines[at] = line;
            // ICU-Punktgrenzen sind weiter als die physischen CR-/LF-Quellzeilen.
            if matches!(*u, 10 | 11 | 12 | 13 | 0x85 | 0x2028 | 0x2029) {
                line += 1;
            }
        }
        lines[index.units.len()] = line;
        let anchored = self.prepare(&format!(r"\A(?:{pattern})"))?;
        let mut output = Vec::new();
        let mut consumed = 0;
        for opening in openings {
            check.now()?;
            let start = opening.range.start;
            if start < consumed {
                continue;
            }
            let marker_end = if double { start + 2 } else { opening.range.end };
            let mut content_start = marker_end;
            if !double {
                while index
                    .units
                    .get(content_start)
                    .is_some_and(|u| matches!(*u, 32 | 9))
                {
                    content_start += 1;
                }
                if index.units.get(content_start) == Some(&10) {
                    content_start += 1;
                }
            }
            // Gieriger öffnender Leerraum hat Vorrang vor dem faulen Inhalt.
            // Erst wenn danach kein Ende existiert, darf er zurückweichen.
            let candidate = |after: usize| -> Option<&Range<usize>> {
                let c = closings.get(closings.partition_point(|r| r.start <= after))?;
                (!double || lines[c.start] == lines[start]).then_some(c)
            };
            let Some(end) = candidate(content_start)
                .or_else(|| (!double).then(|| candidate(marker_end)).flatten())
            else {
                continue;
            };
            let bytes = index.bytes(&(start..end.end))?;
            let matches = self.scan_prepared(&anchored, &source[bytes], check)?;
            let Some(hit) = matches.into_iter().next() else {
                // Wie boundedMatches am Mac: ein Kandidat kann regulär nicht passen.
                continue;
            };
            if hit.range.start != 0 {
                return Err(Error::Invariant);
            }
            let range = (start + hit.range.start)..(start + hit.range.end);
            let content = (start + hit.content.start)..(start + hit.content.end);
            consumed = range.end;
            output.push(Hit { range, content });
        }
        Ok(output)
    }
}
#[derive(Clone, Debug)]
pub struct Extraction {
    formulas: Vec<Formula>,
    tokens: Vec<Token>,
    view: View,
    source: String,
    byte_to_utf16: Vec<usize>,
    source_lines: Vec<usize>,
    prepared_lines: Vec<usize>,
}
impl Extraction {
    pub fn prepared(&self) -> &str {
        &self.view.text
    }
    pub fn formulas(&self) -> &[Formula] {
        &self.formulas
    }
    pub fn tokens(&self) -> &[Token] {
        &self.tokens
    }
    pub fn original_range(&self, prepared: Range<usize>) -> Result<SourceRange, Error> {
        let bytes = self.view.original_range(&prepared)?;
        let a = *self.byte_to_utf16.get(bytes.start).ok_or(Error::Boundary)?;
        let b = *self.byte_to_utf16.get(bytes.end).ok_or(Error::Boundary)?;
        if a == usize::MAX || b == usize::MAX {
            return Err(Error::Boundary);
        }
        Ok(SourceRange { bytes, utf16: a..b })
    }
    pub(super) fn source_position(&self, original_byte: usize) -> Result<(usize, usize), Error> {
        let utf16 = *self
            .byte_to_utf16
            .get(original_byte)
            .ok_or(Error::Boundary)?;
        if utf16 == usize::MAX {
            return Err(Error::Boundary);
        }
        let line = self
            .source_lines
            .partition_point(|start| *start <= original_byte)
            .max(1);
        Ok((
            line,
            utf16 - self.byte_to_utf16[self.source_lines[line - 1]] + 1,
        ))
    }
    pub(super) fn original_line_at(&self, prepared_byte: usize) -> Result<usize, Error> {
        self.view.original_boundary(prepared_byte)?;
        self.original_line(
            self.prepared_lines
                .partition_point(|start| *start <= prepared_byte),
        )
    }
    pub fn original_line(&self, prepared_line: usize) -> Result<usize, Error> {
        if prepared_line == 0 {
            return Ok(1);
        }
        if self.prepared_lines.len() == self.source_lines.len() {
            return Ok(prepared_line);
        }
        let Some(at) = self.prepared_lines.get(prepared_line - 1).copied() else {
            return Ok(self.source_lines.len() + 1);
        };
        let original = self.view.original_boundary(at)?;
        Ok(self
            .source_lines
            .partition_point(|start| *start <= original))
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub(crate) fn protected_regions(
        &self,
        budget: Budget,
        cancel: &Cancellation,
    ) -> Result<Vec<Range<usize>>, Error> {
        if self
            .view
            .segments
            .iter()
            .any(|s| matches!(s.kind, Kind::Math(_) | Kind::Mark))
        {
            return Err(Error::Invariant);
        }
        let mut check = Check { cancel, hook: None };
        let index = Index::new(self.prepared(), &mut check)?;
        let ranges = ranges_in_view(
            &self.view,
            &index,
            &self.byte_to_utf16,
            budget,
            cancel,
            &mut check,
        )?;
        Ok(merged_regions(ranges))
    }
    pub(super) fn generated_mark(&self, range: &Range<usize>) -> bool {
        let at = self
            .view
            .segments
            .partition_point(|s| s.output.start < range.start);
        self.view
            .segments
            .get(at)
            .is_some_and(|s| s.output == *range && s.kind == Kind::Mark)
    }
    pub(super) fn apply_marks(
        &mut self,
        changes: Vec<(Range<usize>, String)>,
        budget: Budget,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        let mut check = Check { cancel, hook: None };
        self.view = self.view.replace(
            changes
                .into_iter()
                .map(|(range, text)| (range, text, Kind::Mark))
                .collect(),
            budget,
            &mut check,
        )?;
        self.refresh();
        Ok(())
    }
    fn refresh(&mut self) {
        self.tokens = self
            .view
            .segments
            .iter()
            .filter_map(|s| {
                if let Kind::Math(formula) = s.kind {
                    Some(Token {
                        prepared: s.output.clone(),
                        formula,
                    })
                } else {
                    None
                }
            })
            .collect();
        self.prepared_lines = std::iter::once(0)
            .chain(
                self.view
                    .text
                    .bytes()
                    .enumerate()
                    .filter_map(|(at, b)| (b == b'\n').then_some(at + 1)),
            )
            .collect();
    }
    pub(super) fn apply_links(
        &mut self,
        ranges: &[Range<usize>],
        budget: Budget,
        cancel: &Cancellation,
    ) -> Result<(), Error> {
        let mut check = Check { cancel, hook: None };
        let changes = ranges
            .iter()
            .enumerate()
            .map(|(id, range)| {
                (
                    range.clone(),
                    format!("FASTRAAUTOLINK{id:032X}TOKEN"),
                    Kind::Link(id),
                )
            })
            .collect();
        self.view = self.view.replace(changes, budget, &mut check)?;
        self.refresh();
        Ok(())
    }
    pub(super) fn link_tokens(&self) -> impl Iterator<Item = (Range<usize>, usize)> + '_ {
        self.view.segments.iter().filter_map(|segment| {
            if let Kind::Link(id) = segment.kind {
                Some((segment.output.clone(), id))
            } else {
                None
            }
        })
    }
    /// Nutzertext mit identischen Tokenbytes an einer anderen Position bleibt
    /// gewöhnlicher Text. Consumer dürfen nicht nach bloßen Tokennamen ersetzen.
    pub fn token_at(&self, range: &Range<usize>) -> Option<&Token> {
        self.tokens
            .binary_search_by_key(&range.start, |token| token.prepared.start)
            .ok()
            .and_then(|i| self.tokens.get(i))
            .filter(|t| t.prepared == *range)
    }
}
fn range_at(
    view: &View,
    index: &Index,
    range: &Range<usize>,
    original_index: &[usize],
) -> Result<SourceRange, Error> {
    let current = index.bytes(range)?;
    let original = view.original_range(&current)?;
    let a = original_index[original.start];
    let b = original_index[original.end];
    if a == usize::MAX || b == usize::MAX {
        return Err(Error::Boundary);
    }
    Ok(SourceRange {
        bytes: original,
        utf16: a..b,
    })
}
fn token(prefix: &str, sequence: &mut usize) -> Result<String, Error> {
    // Nur die registrierte Position verleiht einem Token Bedeutung. Gleiche
    // Nutzerbytes an anderer Stelle bleiben dadurch vollständig gewöhnlicher Text.
    let value = format!("FASTRA{prefix}{:032X}TOKEN", *sequence);
    *sequence = sequence.checked_add(1).ok_or(Error::Limit)?;
    Ok(value)
}

/// Bereichsanalyse wie beim Mac: CR/CRLF werden nur in der Analyseansicht zu
/// LF. Die Ergebnisse zeigen immer auf unveränderte Originalbytes und -UTF16.
pub fn formula_ranges(
    source: &str,
    budget: Budget,
    cancel: &Cancellation,
) -> Result<Vec<SourceRange>, Error> {
    formula_ranges_checked(source, budget, cancel, &mut || Ok(()))
}
fn formula_ranges_checked(
    source: &str,
    budget: Budget,
    cancel: &Cancellation,
    hook: &mut dyn FnMut() -> Result<(), Error>,
) -> Result<Vec<SourceRange>, Error> {
    let mut check = Check {
        cancel,
        hook: Some(hook),
    };
    check.now()?;
    if source.len() > budget.source_bytes {
        return Err(Error::Limit);
    }
    let view = View::normalized(source, &mut check)?;
    let index = Index::new(&view.text, &mut check)?;
    let (original_index, _) = source_index(source, &mut check)?;
    ranges_in_view(&view, &index, &original_index, budget, cancel, &mut check)
}
fn ranges_in_view(
    view: &View,
    index: &Index,
    original_index: &[usize],
    budget: Budget,
    cancel: &Cancellation,
    check: &mut Check<'_>,
) -> Result<Vec<SourceRange>, Error> {
    let engine = Engine {
        budget,
        cancel: cancel.clone(),
    };
    let mut code = engine.bounded(FENCE, &view.text, index, check)?;
    code.extend(engine.bounded(CODE, &view.text, index, check)?);
    code.sort_by_key(|hit| hit.range.start);
    let mut ends = Vec::with_capacity(code.len());
    for hit in &code {
        ends.push(hit.range.end.max(ends.last().copied().unwrap_or(0)));
    }
    let mut output = Vec::new();
    for pattern in [BLOCK, DOUBLE, SINGLE] {
        for hit in engine.bounded(pattern, &view.text, index, check)? {
            check.now()?;
            let before = code.partition_point(|code| code.range.start < hit.range.end);
            if before == 0 || ends[before - 1] <= hit.range.start {
                output.push(range_at(view, index, &hit.range, original_index)?);
            }
        }
    }
    Ok(output)
}
pub(super) fn merged_regions(ranges: Vec<SourceRange>) -> Vec<Range<usize>> {
    let mut ranges = ranges.into_iter().map(|r| r.bytes).collect::<Vec<_>>();
    ranges.sort_by_key(|r| r.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        if let Some(last) = merged.last_mut().filter(|last| last.end >= range.start) {
            last.end = last.end.max(range.end);
        } else {
            merged.push(range);
        }
    }
    merged
}
/// Nur EOL-Ansicht für Consumer, die Formeln weiterhin als Originalatome schützen.
pub(crate) fn normalized(
    source: &str,
    budget: Budget,
    cancel: &Cancellation,
) -> Result<Extraction, Error> {
    cancel.check()?;
    if source.len() > budget.source_bytes {
        return Err(Error::Limit);
    }
    let mut check = Check { cancel, hook: None };
    let (byte_to_utf16, source_lines) = source_index(source, &mut check)?;
    let view = View::normalized(source, &mut check)?;
    if view.text.len() > budget.view_bytes {
        return Err(Error::Limit);
    }
    let prepared_lines = std::iter::once(0)
        .chain(
            view.text
                .bytes()
                .enumerate()
                .filter_map(|(at, b)| (b == b'\n').then_some(at + 1)),
        )
        .collect();
    Ok(Extraction {
        formulas: Vec::new(),
        tokens: Vec::new(),
        view,
        source: source.into(),
        byte_to_utf16,
        source_lines,
        prepared_lines,
    })
}
#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "Unveränderte Mac-Referenzschnittstelle; Consumer verwenden den bereits gemappten Einstieg."
    )
)]
pub fn extract(source: &str, budget: Budget, cancel: &Cancellation) -> Result<Extraction, Error> {
    extract_checked(source, budget, cancel, &mut || Ok(()))
}
#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "Prüfbarer Abbruchpfad der unveränderten Mac-Referenzschnittstelle."
    )
)]
fn extract_checked(
    source: &str,
    budget: Budget,
    cancel: &Cancellation,
    hook: &mut dyn FnMut() -> Result<(), Error>,
) -> Result<Extraction, Error> {
    let mut check = Check {
        cancel,
        hook: Some(hook),
    };
    check.now()?;
    if source.len() > budget.source_bytes {
        return Err(Error::Limit);
    }
    let (original_index, source_lines) = source_index(source, &mut check)?;
    let view = View::normalized(source, &mut check)?;
    let mapped = Extraction {
        formulas: Vec::new(),
        tokens: Vec::new(),
        view,
        source: source.into(),
        byte_to_utf16: original_index,
        source_lines,
        prepared_lines: Vec::new(),
    };
    extract_view(mapped, &[], budget, cancel, &mut check)
}
/// Der Consumer kann weitere, vom bestehenden Markdown-Parser belegte Literale
/// schützen. Die öffentliche Mac-Regex-Extraktion bleibt dabei unverändert.
pub(super) fn extract_mapped(
    mapped: Extraction,
    literals: &[Range<usize>],
    budget: Budget,
    cancel: &Cancellation,
) -> Result<Extraction, Error> {
    let mut check = Check { cancel, hook: None };
    extract_view(mapped, literals, budget, cancel, &mut check)
}
fn extract_view(
    mapped: Extraction,
    literals: &[Range<usize>],
    budget: Budget,
    cancel: &Cancellation,
    check: &mut Check<'_>,
) -> Result<Extraction, Error> {
    let Extraction {
        mut view,
        source,
        byte_to_utf16: original_index,
        source_lines,
        ..
    } = mapped;
    let engine = Engine {
        budget,
        cancel: cancel.clone(),
    };
    let mut literal_ends = Vec::with_capacity(literals.len());
    let mut last_start = 0;
    for range in literals {
        check.now()?;
        if range.start < last_start
            || range.start > range.end
            || range.end > source.len()
            || original_index[range.start] == usize::MAX
            || original_index[range.end] == usize::MAX
        {
            return Err(Error::Boundary);
        }
        last_start = range.start;
        literal_ends.push(range.end.max(literal_ends.last().copied().unwrap_or(0)));
    }
    let mut codes = Vec::<View>::new();
    let mut sequence = 0;
    for pattern in [FENCE, CODE] {
        let index = Index::new(&view.text, check)?;
        let mut changes = Vec::new();
        for hit in engine.bounded(pattern, &view.text, &index, check)? {
            let range = index.bytes(&hit.range)?;
            let mut code = View {
                text: String::new(),
                segments: Vec::new(),
            };
            view.append_range(range.clone(), &mut code, check)?;
            let id = codes.len();
            codes.push(code);
            changes.push((range, token("CODEBLOCK", &mut sequence)?, Kind::Code(id)));
        }
        view = view.replace(changes, budget, check)?;
    }
    let mut formulas = Vec::new();
    for pattern in [BLOCK, DOUBLE, SINGLE] {
        let index = Index::new(&view.text, check)?;
        let mut changes = Vec::new();
        for hit in engine.bounded(pattern, &view.text, &index, check)? {
            check.now()?;
            let tex = view.text[index.bytes(&hit.content)?]
                .trim_matches(char::is_whitespace)
                .to_owned();
            if tex.is_empty() {
                continue;
            }
            let original = range_at(&view, &index, &hit.range, &original_index)?;
            let before = literals.partition_point(|r| r.start <= original.bytes.start);
            let through = literals.partition_point(|r| r.start < original.bytes.end);
            // Ein Dollar im Literal darf dessen Grenze nicht verlassen. Ganze
            // eingeschlossene Codebereiche bleiben dagegen nested_tokens-Quelle.
            if (before > 0 && literal_ends[before - 1] > original.bytes.start)
                || (through > 0 && literal_ends[through - 1] > original.bytes.end)
            {
                continue;
            }
            let content = range_at(&view, &index, &hit.content, &original_index)?;
            let id = formulas.len();
            let current_content = index.bytes(&hit.content)?;
            let first = view
                .segments
                .partition_point(|s| s.output.end <= current_content.start);
            let nested_tokens = view.segments[first..]
                .iter()
                .take_while(|s| s.output.start < current_content.end)
                .any(|s| matches!(s.kind, Kind::Code(_) | Kind::Math(_)));
            formulas.push(Formula {
                source: original,
                content,
                captured_tex: tex,
                nested_tokens,
                block: pattern == BLOCK,
            });
            changes.push((
                index.bytes(&hit.range)?,
                token("MATH", &mut sequence)?,
                Kind::Math(id),
            ));
        }
        view = view.replace(changes, budget, check)?;
    }
    let mut restored = View {
        text: String::new(),
        segments: Vec::new(),
    };
    for segment in &view.segments {
        check.now()?;
        if let Kind::Code(id) = segment.kind {
            let code = &codes[id];
            code.append_range(0..code.text.len(), &mut restored, check)?;
        } else {
            restored.push(
                &view.text[segment.output.clone()],
                segment.original.clone(),
                segment.kind,
            );
        }
        if restored.text.len() > budget.view_bytes {
            return Err(Error::Limit);
        }
    }
    let tokens = restored
        .segments
        .iter()
        .filter_map(|s| {
            if let Kind::Math(formula) = s.kind {
                Some(Token {
                    prepared: s.output.clone(),
                    formula,
                })
            } else {
                None
            }
        })
        .collect();
    check.now()?;
    let prepared_lines = std::iter::once(0)
        .chain(
            restored
                .text
                .bytes()
                .enumerate()
                .filter_map(|(at, b)| (b == b'\n').then_some(at + 1)),
        )
        .collect();
    Ok(Extraction {
        formulas,
        tokens,
        view: restored,
        source,
        byte_to_utf16: original_index,
        source_lines,
        prepared_lines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn reference(source: &str) -> Vec<SourceRange> {
        let cancel = Cancellation::default();
        let mut check = Check {
            cancel: &cancel,
            hook: None,
        };
        let view = View::normalized(source, &mut check).unwrap();
        let index = Index::new(&view.text, &mut check).unwrap();
        let (original, _) = source_index(source, &mut check).unwrap();
        let engine = Engine {
            budget: Budget::default(),
            cancel: cancel.clone(),
        };
        let all = [FENCE, CODE, BLOCK, DOUBLE, SINGLE]
            .map(|pattern| engine.scan(pattern, &view.text, &mut check).unwrap());
        let code = all[0].iter().chain(all[1].iter()).collect::<Vec<_>>();
        all[2..]
            .iter()
            .flat_map(|hits| hits.iter())
            .filter(|h| {
                !code
                    .iter()
                    .any(|c| c.range.start < h.range.end && h.range.start < c.range.end)
            })
            .map(|h| range_at(&view, &index, &h.range, &original).unwrap())
            .collect()
    }
    #[test]
    fn original_mac_seed_127_and_2000_syntax_vectors() {
        let chunks = [
            "$",
            "$$",
            "$$$$$",
            "`",
            "```\n",
            "````a\n",
            "~~~\n",
            "~~~~\n",
            "a\n",
            "\n",
            "$$\n",
            "$$x$$\n",
            "\t```\n",
            "    ```\n",
            "``` \u{2028}",
            "`$x$`\n",
            " ",
            "\t",
            "\\",
            "😀",
            "\u{85}",
            "\u{2029}",
        ];
        let examples = [
            "$$$$$",
            "$$\n$$\n$$",
            "````\nx\n```\ny\n````",
            "`$x$`\n$$\n```\n~~~~\n``` \u{2028}~~~\n~~~~\n$$\n\n\t```\n~~~\n",
        ];
        for source in examples {
            assert_eq!(
                formula_ranges(source, Budget::default(), &Cancellation::default()).unwrap(),
                reference(source),
                "{source:?}"
            );
        }
        let mut seed = 127u64;
        let mut next = |count: usize| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((seed >> 32) % (count as u64)) as usize
        };
        for case in 0..2000 {
            let count = next(20);
            let source = (0..count)
                .map(|_| chunks[next(chunks.len())])
                .collect::<String>();
            assert_eq!(
                formula_ranges(&source, Budget::default(), &Cancellation::default()).unwrap(),
                reference(&source),
                "case {case}: {source:?}"
            );
        }
    }
    #[test]
    fn original_mac_large_incomplete_and_100000_inline() {
        let cancel = Cancellation::default();
        let budget = Budget::default();
        assert!(
            formula_ranges(&"```a\n![x](no)\n".repeat(20_000), budget, &cancel)
                .unwrap()
                .is_empty()
        );
        assert!(
            formula_ranges(&"$$a$ [x](target) `a` ".repeat(20_000), budget, &cancel)
                .unwrap()
                .is_empty()
        );
        let source = "`x` $a$ ".repeat(100_000);
        let ranges = formula_ranges(&source, budget, &cancel).unwrap();
        assert_eq!(ranges.len(), 100_000);
        assert_eq!(ranges[0].utf16, 4..7);
        assert_eq!(ranges.last().unwrap().utf16, 799_996..799_999);
    }
    #[test]
    fn complete_100000_inline_extraction_remains_finitely_mapped() {
        let source = "`x` $a$ ".repeat(100_000);
        let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(e.tokens().len(), 100_000);
        assert_eq!(e.formulas().len(), 100_000);
        assert_eq!(e.formulas().last().unwrap().source.utf16, 799_996..799_999);
        assert!(e.prepared().len() <= Budget::default().view_bytes);
        assert!(e
            .formulas()
            .iter()
            .all(|f| f.captured_tex == "a" && !f.block));
        assert_eq!(e.source(), source);
    }
    #[test]
    fn repeated_matched_blocks_do_not_copy_the_remaining_document_per_match() {
        let source = "$$\nx\n$$\n".repeat(20_000);
        let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(e.tokens().len(), 20_000);
        assert_eq!(e.original_line(20_000).unwrap(), 59_998);
    }
    #[test]
    fn original_mac_1000_block_mapping() {
        let source = (0..1000)
            .map(|n| format!("$$\nx_{n}\n$$\n\nLine{n}\n"))
            .collect::<String>();
        let extraction = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(extraction.tokens().len(), 1000);
        assert!(extraction.formulas().iter().all(|f| f.block));
        assert_eq!(extraction.formulas().last().unwrap().captured_tex, "x_999");
        let prepared_line = extraction
            .prepared()
            .split('\n')
            .position(|line| line == "Line999")
            .unwrap()
            + 1;
        assert_eq!(extraction.original_line(prepared_line).unwrap(), 5000);
        let pos = extraction.prepared().find("Line999").unwrap();
        assert_eq!(
            &source[extraction.original_range(pos..pos + 7).unwrap().bytes],
            "Line999"
        );
    }
    #[test]
    fn original_mac_cancellation_at_twentieth_checkpoint() {
        let source = "```a\n![x](no)\n".repeat(20_000);
        let cancel = Cancellation::default();
        let mut checks = 0;
        let result = formula_ranges_checked(&source, Budget::default(), &cancel, &mut || {
            checks += 1;
            if checks == 20 {
                cancel.cancel();
            }
            cancel.check().map_err(Error::from)
        });
        assert_eq!(checks, 20);
        assert_eq!(result, Err(Error::Core(fastra_core::Error::Cancelled)));
    }
    #[test]
    fn actual_cancellation_during_extraction_has_no_partial_value() {
        let source = "`x` $a$ ".repeat(100_000);
        let cancel = Cancellation::default();
        let other = cancel.clone();
        let worker = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(1));
            other.cancel();
        });
        let result = extract(&source, Budget::default(), &cancel);
        worker.join().unwrap();
        assert!(matches!(
            result,
            Err(Error::Core(fastra_core::Error::Cancelled))
        ));
    }
    #[test]
    fn explicit_crlf_cr_and_utf16_original_positions() {
        for ending in ["\n", "\r\n", "\r"] {
            let source=format!("😀 before{ending}{ending}$$ {ending} x + 雪 {ending}$$ {ending}{ending}After😀{ending}");
            let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
            assert_eq!(e.source(), source);
            assert_eq!(e.tokens().len(), 1);
            assert_eq!(e.formulas()[0].captured_tex, "x + 雪");
            assert_eq!(
                &source[e.formulas()[0].source.bytes.clone()],
                format!("$$ {ending} x + 雪 {ending}$$ ")
            );
            let after = e.prepared().find("After😀").unwrap();
            let original = e.original_range(after..after + "After😀".len()).unwrap();
            assert_eq!(&source[original.bytes.clone()], "After😀");
            assert_eq!(
                source[..original.bytes.start].encode_utf16().count(),
                original.utf16.start
            );
            let prepared_line = e.prepared()[..after].bytes().filter(|b| *b == 10).count() + 1;
            assert_eq!(e.original_line(prepared_line).unwrap(), 7);
        }
    }
    #[test]
    fn mapped_cr_code_view_does_not_modify_original_code_bytes() {
        let source = "```text\ralpha\r  \rbeta\r```\rAfter";
        let e = extract(source, Budget::default(), &Cancellation::default()).unwrap();
        assert!(e.tokens().is_empty());
        assert_eq!(e.prepared(), "```text\nalpha\n  \nbeta\n```\nAfter");
        assert_eq!(e.source(), source);
        let at = e.prepared().find("alpha").unwrap();
        let end = e.prepared().find("beta").unwrap() + 4;
        assert_eq!(
            &source[e.original_range(at..end).unwrap().bytes],
            "alpha\r  \rbeta"
        );
        assert_eq!(e.original_line(6).unwrap(), 6);
    }
    #[test]
    fn only_registered_ranges_are_tokens_even_with_identical_user_text() {
        let fake = "FASTRAMATH00000000000000000000000000000000TOKEN";
        let source = format!("{fake} $x$");
        let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(e.tokens().len(), 1);
        assert!(e.token_at(&(0..fake.len())).is_none());
        let t = &e.tokens()[0];
        assert!(e.token_at(&t.prepared).is_some());
        assert_eq!(&source[e.formulas()[t.formula].source.bytes.clone()], "$x$");
        assert!(e
            .original_range(t.prepared.start + 1..t.prepared.end)
            .is_err());
    }
    #[test]
    fn code_protection_and_whitespace_only_extraction_are_distinct_from_ranges() {
        let source = "`$x$`\n\n```\n$$x$$\n```\n\n$y$";
        let e = extract(source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(e.tokens().len(), 1);
        assert_eq!(e.formulas()[0].captured_tex, "y");
        assert!(e.prepared().contains("`$x$`"));
        assert!(e.prepared().contains("```\n$$x$$\n```"));
        let empty = "$$\n  \n$$";
        assert!(
            !formula_ranges(empty, Budget::default(), &Cancellation::default())
                .unwrap()
                .is_empty()
        );
        let e = extract(empty, Budget::default(), &Cancellation::default()).unwrap();
        assert!(e.tokens().is_empty());
        assert_eq!(e.prepared(), empty);
    }
    #[test]
    fn existing_mac_code_range_and_extraction_precedence_stay_explicit() {
        let source = "$`x`$";
        assert!(
            formula_ranges(source, Budget::default(), &Cancellation::default())
                .unwrap()
                .is_empty()
        );
        let e = extract(source, Budget::default(), &Cancellation::default()).unwrap();
        assert_eq!(e.tokens().len(), 1);
        let formula = &e.formulas()[e.tokens()[0].formula];
        assert!(formula.nested_tokens);
        assert!(formula.captured_tex.starts_with("FASTRACODE"));
        assert_eq!(&source[formula.content.bytes.clone()], "`x`");
        assert_eq!(&source[formula.source.bytes.clone()], source);
    }
    #[test]
    fn literal_remainder_mapping_and_unicode_regex_line_boundaries() {
        for source in [
            "雪\r\n$a$ 😀\r\nend",
            "$$a\u{2028}b$$",
            "$$a\u{85}b$$",
            "$$a\u{2029}b$$",
            "A $a$ B $$x$$ C",
            "$$ $$ $$",
            "$$\n$$\n$$",
        ] {
            assert_eq!(
                formula_ranges(source, Budget::default(), &Cancellation::default()).unwrap(),
                reference(source)
            );
            let e = extract(source, Budget::default(), &Cancellation::default()).unwrap();
            for s in &e.view.segments {
                if matches!(s.kind, Kind::Original) {
                    assert_eq!(&e.prepared()[s.output.clone()], &source[s.original.clone()]);
                }
            }
        }
    }
    #[test]
    fn icu_dot_line_boundaries_keep_unmatched_double_dollars_literal() {
        for separator in ['\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}'] {
            let source = format!("before $$a{separator}b$$ after");
            assert!(reference(&source).is_empty(), "{source:?}");
            assert_eq!(
                formula_ranges(&source, Budget::default(), &Cancellation::default()),
                Ok(Vec::new()),
                "{source:?}"
            );
            let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
            assert_eq!(e.source(), source);
            assert_eq!(e.prepared(), source);
            assert!(e.formulas().is_empty());
            assert!(e.tokens().is_empty());
            assert_eq!(e.source_lines, vec![0]);
            assert_eq!(e.prepared_lines, vec![0]);
            assert_eq!(
                e.original_range(0..source.len()).unwrap().bytes,
                0..source.len()
            );
            // Block-Dotall und die negierte Single-Dollar-Klasse dürfen dieselben
            // Zeichen im Inhalt enthalten; nur Inline-Double nutzt den ICU-Punkt.
            for (source, block) in [
                (format!("$$a{separator}b$$"), true),
                (format!("before $a{separator}b$ after"), false),
            ] {
                assert_eq!(
                    formula_ranges(&source, Budget::default(), &Cancellation::default()).unwrap(),
                    reference(&source)
                );
                let e = extract(&source, Budget::default(), &Cancellation::default()).unwrap();
                assert_eq!(e.formulas().len(), 1, "{source:?}");
                assert_eq!(e.formulas()[0].captured_tex, format!("a{separator}b"));
                assert_eq!(e.formulas()[0].block, block);
            }
        }
    }
    // Direkte Gesamtausdrücke und rückwärtige Stringersetzungen bilden eine
    // unabhängige Gegenprobe zur begrenzten Kandidaten-/Segmentverarbeitung.
    fn reference_extraction(source: &str) -> (String, Vec<(String, bool)>) {
        let cancel = Cancellation::default();
        let mut check = Check {
            cancel: &cancel,
            hook: None,
        };
        let engine = Engine {
            budget: Budget::default(),
            cancel: cancel.clone(),
        };
        let mut work = source.to_owned();
        let mut codes = Vec::new();
        let mut formulas = Vec::new();
        let mut sequence = 0usize;
        for (stage, pattern) in [FENCE, CODE, BLOCK, DOUBLE, SINGLE].iter().enumerate() {
            let index = Index::new(&work, &mut check).unwrap();
            let mut changes = Vec::new();
            for hit in engine.scan(pattern, &work, &mut check).unwrap() {
                let range = index.bytes(&hit.range).unwrap();
                let marker = if stage < 2 {
                    let marker = format!("FASTRACODEBLOCK{sequence:032X}TOKEN");
                    codes.push((marker.clone(), work[range.clone()].to_owned()));
                    marker
                } else {
                    let tex = work[index.bytes(&hit.content).unwrap()].trim().to_owned();
                    if tex.is_empty() {
                        continue;
                    }
                    formulas.push((tex, stage == 2));
                    format!("FASTRAMATH{sequence:032X}TOKEN")
                };
                sequence += 1;
                changes.push((range, marker));
            }
            for (range, marker) in changes.into_iter().rev() {
                work.replace_range(range, &marker);
            }
        }
        for (marker, code) in codes {
            work = work.replace(&marker, &code);
        }
        (work, formulas)
    }
    #[test]
    fn vt_ff_extended_differential_ranges_extraction_and_original_mapping() {
        let chunks = [
            "$", "$$", "$$$", "$$$$", "\\$", "a", "😀", "雪", "\n", "\r", "\r\n", "\t", " ",
            "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}", "\u{2007}", "`", "``", "```\n",
            "````\n", "~~~\n", "~~~~\n", "`a`", "$$x$$\n",
        ];
        let mut seed = 0x98732c239423u64;
        let mut next = |count| {
            seed = seed
                .wrapping_mul(2862933555777941757)
                .wrapping_add(3037000493);
            ((seed >> 32) as usize) % count
        };
        for case in 0..5000 {
            let count = next(40);
            let source = (0..count)
                .map(|_| chunks[next(chunks.len())])
                .collect::<String>();
            let normalized = source.replace("\r\n", "\n").replace('\r', "\n");
            let actual_ranges =
                formula_ranges(&source, Budget::default(), &Cancellation::default())
                    .unwrap_or_else(|e| panic!("ranges {e:?}, case {case}: {source:?}"));
            assert_eq!(
                actual_ranges,
                reference(&source),
                "ranges case {case}: {source:?}"
            );
            let (prepared, formulas) = reference_extraction(&normalized);
            let actual = extract(&source, Budget::default(), &Cancellation::default())
                .unwrap_or_else(|e| panic!("extract {e:?}, case {case}: {source:?}"));
            assert_eq!(actual.source(), source);
            assert_eq!(
                actual.prepared(),
                prepared,
                "prepared case {case}: {source:?}"
            );
            assert_eq!(
                actual
                    .formulas()
                    .iter()
                    .map(|f| (f.captured_tex.clone(), f.block))
                    .collect::<Vec<_>>(),
                formulas,
                "formulas case {case}: {source:?}"
            );
            for token in actual.tokens() {
                let original = actual.original_range(token.prepared.clone()).unwrap();
                assert_eq!(original, actual.formulas()[token.formula].source);
                assert_eq!(
                    original.utf16.start,
                    source[..original.bytes.start].encode_utf16().count()
                );
                assert_eq!(
                    original.utf16.end,
                    source[..original.bytes.end].encode_utf16().count()
                );
            }
        }
    }
    #[test]
    fn finite_source_and_virtual_budgets_fail_without_partial_output() {
        let b = Budget {
            source_bytes: 2,
            ..Budget::default()
        };
        assert_eq!(
            formula_ranges("$xx$", b, &Cancellation::default()),
            Err(Error::Limit)
        );
        let b = Budget {
            view_bytes: 10,
            ..Budget::default()
        };
        assert!(extract("$x$", b, &Cancellation::default()).is_err());
        assert!(matches!(
            normalized("plain text beyond view", b, &Cancellation::default()),
            Err(Error::Limit)
        ));
    }
}
