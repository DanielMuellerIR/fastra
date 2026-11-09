//! Gemeinsame begrenzte Parseransicht mit unveränderten Originalpositionen.
use fastra_core::Cancellation;
use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Core(fastra_core::Error),
    Limit,
    Boundary,
    Invariant,
}
impl From<fastra_core::Error> for Error {
    fn from(value: fastra_core::Error) -> Self {
        Self::Core(value)
    }
}
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub source_bytes: usize,
    pub view_bytes: usize,
    pub matches: usize,
    pub regex_ms: i32,
}
impl Default for Budget {
    fn default() -> Self {
        Self {
            source_bytes: 4 * 1024 * 1024,
            view_bytes: 16 * 1024 * 1024,
            matches: 100_000,
            regex_ms: 100,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceRange {
    /// Halboffener UTF8-Bytebereich der unveränderten Dokumentquelle.
    pub bytes: Range<usize>,
    /// Derselbe Originalbereich in UTF16-Codeeinheiten.
    pub utf16: Range<usize>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Original,
    Normalized,
    Code(usize),
    Math(usize),
    Link(usize),
    Mark,
}
#[derive(Clone, Debug)]
pub(super) struct Segment {
    pub(super) output: Range<usize>,
    pub(super) original: Range<usize>,
    pub(super) kind: Kind,
}
#[derive(Clone, Debug)]
pub(super) struct View {
    pub(super) text: String,
    pub(super) segments: Vec<Segment>,
}
#[derive(Clone, Debug)]
pub(super) struct Index {
    pub(super) units: Vec<u16>,
    pub(super) to_byte: Vec<usize>,
}
impl Index {
    pub(super) fn new(source: &str, check: &mut Check<'_>) -> Result<Self, Error> {
        let mut units = Vec::new();
        let mut to_byte = vec![0];
        for (at, c) in source.char_indices() {
            if at % 4096 == 0 {
                check.now()?;
            }
            let mut buffer = [0; 2];
            let encoded = c.encode_utf16(&mut buffer);
            units.extend_from_slice(encoded);
            if encoded.len() == 2 {
                to_byte.push(usize::MAX);
            }
            to_byte.push(at + c.len_utf8());
        }
        Ok(Self { units, to_byte })
    }
    pub(super) fn bytes(&self, range: &Range<usize>) -> Result<Range<usize>, Error> {
        let a = *self.to_byte.get(range.start).ok_or(Error::Boundary)?;
        let b = *self.to_byte.get(range.end).ok_or(Error::Boundary)?;
        if a == usize::MAX || b == usize::MAX || a > b {
            return Err(Error::Boundary);
        }
        Ok(a..b)
    }
}
pub(super) struct Check<'a> {
    pub(super) cancel: &'a Cancellation,
    pub(super) hook: Option<&'a mut dyn FnMut() -> Result<(), Error>>,
}
impl Check<'_> {
    pub(super) fn now(&mut self) -> Result<(), Error> {
        self.cancel.check()?;
        if let Some(hook) = self.hook.as_mut() {
            hook()?;
        }
        Ok(())
    }
}
impl View {
    pub(super) fn normalized(source: &str, check: &mut Check<'_>) -> Result<Self, Error> {
        let bytes = source.as_bytes();
        let mut out = Self {
            text: String::with_capacity(source.len()),
            segments: Vec::new(),
        };
        let mut at = 0;
        let mut start = 0;
        while at < bytes.len() {
            if at % 4096 == 0 {
                check.now()?;
            }
            if bytes[at] == b'\r' {
                if start < at {
                    out.push(&source[start..at], start..at, Kind::Original);
                }
                let end = at
                    + if bytes.get(at + 1) == Some(&b'\n') {
                        2
                    } else {
                        1
                    };
                out.push("\n", at..end, Kind::Normalized);
                at = end;
                start = at;
            } else {
                at += 1;
            }
        }
        if start < bytes.len() {
            out.push(&source[start..], start..bytes.len(), Kind::Original);
        }
        Ok(out)
    }
    pub(super) fn push(&mut self, text: &str, original: Range<usize>, kind: Kind) {
        if text.is_empty() {
            return;
        }
        let start = self.text.len();
        self.text.push_str(text);
        if kind == Kind::Original {
            if let Some(last) = self.segments.last_mut() {
                if last.kind == kind
                    && last.output.end == start
                    && last.original.end == original.start
                {
                    last.output.end = self.text.len();
                    last.original.end = original.end;
                    return;
                }
            }
        }
        self.segments.push(Segment {
            output: start..self.text.len(),
            original,
            kind,
        });
    }
    pub(super) fn original_boundary(&self, at: usize) -> Result<usize, Error> {
        if at > self.text.len() || !self.text.is_char_boundary(at) {
            return Err(Error::Boundary);
        }
        if at == self.text.len() {
            return Ok(self.segments.last().map_or(0, |s| s.original.end));
        }
        let s = self
            .segments
            .get(self.segments.partition_point(|s| s.output.end <= at))
            .ok_or(Error::Boundary)?;
        if at == s.output.start {
            return Ok(s.original.start);
        }
        if s.kind == Kind::Original {
            Ok(s.original.start + at - s.output.start)
        } else {
            Err(Error::Boundary)
        }
    }
    pub(super) fn original_range(&self, range: &Range<usize>) -> Result<Range<usize>, Error> {
        Ok(self.original_boundary(range.start)?..self.original_boundary(range.end)?)
    }
    pub(super) fn append_range(
        &self,
        range: Range<usize>,
        out: &mut View,
        check: &mut Check<'_>,
    ) -> Result<(), Error> {
        let mut i = self
            .segments
            .partition_point(|s| s.output.end <= range.start);
        while let Some(s) = self.segments.get(i) {
            check.now()?;
            if s.output.start >= range.end {
                break;
            }
            let part = s.output.start.max(range.start)..s.output.end.min(range.end);
            let original = self.original_range(&part)?;
            out.push(&self.text[part], original, s.kind);
            i += 1;
        }
        Ok(())
    }
    pub(super) fn replace(
        &self,
        changes: Vec<(Range<usize>, String, Kind)>,
        budget: Budget,
        check: &mut Check<'_>,
    ) -> Result<View, Error> {
        let mut out = View {
            text: String::new(),
            segments: Vec::new(),
        };
        let mut cursor = 0;
        for (range, text, kind) in changes {
            check.now()?;
            if range.start < cursor || range.end > self.text.len() {
                return Err(Error::Boundary);
            }
            self.append_range(cursor..range.start, &mut out, check)?;
            let original = self.original_range(&range)?;
            out.push(&text, original, kind);
            if out.text.len() > budget.view_bytes {
                return Err(Error::Limit);
            }
            cursor = range.end;
        }
        self.append_range(cursor..self.text.len(), &mut out, check)?;
        if out.text.len() > budget.view_bytes {
            return Err(Error::Limit);
        }
        Ok(out)
    }
}
pub(super) fn source_index(
    source: &str,
    check: &mut Check<'_>,
) -> Result<(Vec<usize>, Vec<usize>), Error> {
    let mut byte_to_utf16 = vec![usize::MAX; source.len() + 1];
    let mut utf16 = 0;
    for (byte, c) in source.char_indices() {
        if byte % 4096 == 0 {
            check.now()?;
        }
        byte_to_utf16[byte] = utf16;
        utf16 += c.len_utf16();
    }
    byte_to_utf16[source.len()] = utf16;
    let mut lines = vec![0];
    let mut at = 0;
    let bytes = source.as_bytes();
    while at < bytes.len() {
        if bytes[at] == 13 {
            at += 1;
            if bytes.get(at) == Some(&10) {
                at += 1;
            }
            lines.push(at);
        } else if bytes[at] == 10 {
            at += 1;
            lines.push(at);
        } else {
            at += 1;
        }
    }
    Ok((byte_to_utf16, lines))
}
