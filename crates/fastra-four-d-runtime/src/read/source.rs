use super::*;
#[derive(Clone)]
pub struct SourceIndex {
    utf16_to_chars: Vec<u32>,
    chars_to_utf16: Vec<u32>,
    lines: Vec<(u32, u32)>,
}
impl SourceIndex {
    pub fn new(source: &str, cancel: &Cancellation) -> Result<Self> {
        if source.len() > MAX_SOURCE {
            return Err(error(ErrorKind::Limit, "Source bytes"));
        }
        let mut utf16_to_chars = vec![0];
        let mut chars_to_utf16 = vec![0];
        let mut lines = Vec::new();
        let mut start = 0;
        let mut chars = 0u32;
        let mut utf16 = 0u32;
        let mut cr = false;
        for c in source.chars() {
            if chars % 512 == 0 {
                check(cancel)?;
            }
            let before = utf16;
            utf16 += c.len_utf16() as u32;
            chars += 1;
            if c.len_utf16() == 2 {
                utf16_to_chars.push(u32::MAX);
            }
            utf16_to_chars.push(chars);
            chars_to_utf16.push(utf16);
            if c == '\n' && cr {
                start = utf16;
            } else if c == '\r' || c == '\n' {
                lines.push((start, before));
                start = utf16;
            }
            cr = c == '\r';
        }
        lines.push((start, utf16));
        check(cancel)?;
        Ok(Self {
            utf16_to_chars,
            chars_to_utf16,
            lines,
        })
    }
    pub fn position(&self, character: usize) -> Result<Position> {
        let utf16 = *self
            .chars_to_utf16
            .get(character)
            .ok_or_else(|| error(ErrorKind::Source, "Cursor outside source"))?;
        let line = self
            .lines
            .partition_point(|(start, _)| *start <= utf16)
            .saturating_sub(1);
        let (start, end) = self.lines[line];
        Ok(Position {
            line: line as u32,
            character: utf16.min(end) - start,
        })
    }
    fn point(&self, p: Position, end: bool) -> Option<usize> {
        let &(start, last) = self.lines.get(p.line as usize)?;
        let offset = start.checked_add(if end {
            p.character.min(last - start)
        } else {
            p.character
        })?;
        if offset > last {
            return None;
        }
        let chars = *self.utf16_to_chars.get(offset as usize)?;
        (chars != u32::MAX).then_some(chars as usize)
    }
    pub fn display_position(&self, position: Position) -> Option<(usize, usize)> {
        let value = self.point(position, false)?;
        let start = self.lines.get(position.line as usize)?.0;
        let start = *self.utf16_to_chars.get(start as usize)? as usize;
        Some((position.line as usize + 1, value - start + 1))
    }
    pub fn span(&self, range: Range) -> Option<std::ops::Range<usize>> {
        let start = self.point(range.start, false)?;
        let end = self.point(range.end, true)?;
        (start <= end).then_some(start..end)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_unicode_crlf_and_clamped_server_line_end() {
        let source = "🙂x\r\nGrüße 🚀\rnext\n";
        let index = SourceIndex::new(source, &Cancellation::default()).unwrap();
        assert_eq!(index.position(1).unwrap().character, 2);
        assert_eq!(index.position(5).unwrap().line, 1);
        let span = index
            .span(Range {
                start: Position {
                    line: 1,
                    character: 0,
                },
                end: Position {
                    line: 1,
                    character: i32::MAX as u32,
                },
            })
            .unwrap();
        assert_eq!(
            source
                .chars()
                .skip(span.start)
                .take(span.len())
                .collect::<String>(),
            "Grüße 🚀"
        );
        assert!(index
            .span(Range {
                start: Position {
                    line: 0,
                    character: 1
                },
                end: Position {
                    line: 0,
                    character: 2
                }
            })
            .is_none());
        assert!(index
            .span(Range {
                start: Position {
                    line: u32::MAX,
                    character: 0
                },
                end: Position {
                    line: 0,
                    character: 0
                }
            })
            .is_none());
    }
}
