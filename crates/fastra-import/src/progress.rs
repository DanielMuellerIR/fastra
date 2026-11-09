//! Das bestehende PMT-Zeilenprotokoll; Rohdiagnosen bleiben zusätzlich im Prozessoutput.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Progress {
    pub phase: Phase,
    pub counts: Option<Counts>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    DetectingInput,
    PreparingOutput,
    Converting,
    Publishing,
    Finished,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Counts {
    pub unit: Unit,
    pub completed: u64,
    pub total: u64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    File,
    Page,
    Sheet,
    Frame,
    Slide,
    Chapter,
    Cell,
    Message,
    Note,
}
impl Progress {
    fn decode(line: &str, prefix: &str) -> Option<Self> {
        let mut fields = line.strip_prefix(prefix)?.split_whitespace();
        let phase = match fields.next()? {
            "detectingInput" => Phase::DetectingInput,
            "preparingOutput" => Phase::PreparingOutput,
            "converting" => Phase::Converting,
            "publishing" => Phase::Publishing,
            "finished" => Phase::Finished,
            _ => return None,
        };
        let generic = Self {
            phase,
            counts: None,
        };
        let Some(unit) = fields.next() else {
            return Some(generic);
        };
        let unit = match unit {
            "file" => Unit::File,
            "page" => Unit::Page,
            "sheet" => Unit::Sheet,
            "frame" => Unit::Frame,
            "slide" => Unit::Slide,
            "chapter" => Unit::Chapter,
            "cell" => Unit::Cell,
            "message" => Unit::Message,
            "note" => Unit::Note,
            _ => return Some(generic),
        };
        let Some((completed, total)) = fields.next().and_then(|f| f.split_once('/')) else {
            return Some(generic);
        };
        let (Ok(completed), Ok(total)) = (completed.parse::<u64>(), total.parse::<u64>()) else {
            return Some(generic);
        };
        if total == 0 || completed > total || fields.next().is_some() {
            return Some(generic);
        }
        Some(Self {
            phase,
            counts: Some(Counts {
                unit,
                completed,
                total,
            }),
        })
    }
}
pub struct ProgressParser {
    prefix: String,
    pending: Vec<u8>,
    discarding: bool,
}
impl ProgressParser {
    pub const LINE_LIMIT: usize = 16 * 1024;
    pub fn new(source_name: &str) -> Self {
        Self {
            prefix: format!("Progress: {source_name}: "),
            pending: Vec::new(),
            discarding: source_name.contains('\n'),
        }
    }
    pub fn is_progress_line(&self, line: &str) -> bool {
        Progress::decode(line, &self.prefix).is_some()
    }
    pub fn consume(&mut self, bytes: &[u8]) -> Option<Progress> {
        let mut latest = None;
        for &byte in bytes {
            if byte == b'\n' {
                if !self.discarding {
                    if let Ok(line) = std::str::from_utf8(&self.pending) {
                        if let Some(progress) = Progress::decode(line, &self.prefix) {
                            latest = Some(progress);
                        }
                    }
                }
                self.pending.clear();
                self.discarding = false;
            } else if !self.discarding {
                if self.pending.len() < Self::LINE_LIMIT {
                    self.pending.push(byte)
                } else {
                    self.pending.clear();
                    self.discarding = true;
                }
            }
        }
        latest
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fragments_colons_and_unicode_cannot_create_unrelated_counts() {
        let mut parser = ProgressParser::new("café: 😀.pdf");
        let line = "Progress: café: 😀.pdf: converting page 2/7\n";
        let mut found = None;
        for &byte in line.as_bytes() {
            if let Some(p) = parser.consume(&[byte]) {
                found = Some(p);
            }
        }
        assert_eq!(
            found.unwrap().counts.unwrap(),
            Counts {
                unit: Unit::Page,
                completed: 2,
                total: 7
            }
        );
        assert!(parser
            .consume(b"Progress: another.pdf: finished page 7/7\n")
            .is_none());
        assert!(parser.consume(b"free diagnostic 100/100\n").is_none());
        assert!(parser
            .consume(b"Progress: caf\xff: converting page 9/9\n")
            .is_none());
    }
    #[test]
    fn unknown_counts_remain_generic_and_long_lines_recover_boundedly() {
        let mut parser = ProgressParser::new("x");
        for line in [
            "converting future 2/3",
            "converting page 2",
            "converting page 9/3",
            "converting page 1/0",
            "converting page -1/2",
        ] {
            let p = parser
                .consume(format!("Progress: x: {line}\n").as_bytes())
                .unwrap();
            assert!(p.counts.is_none());
        }
        assert!(parser
            .consume(&vec![b'x'; ProgressParser::LINE_LIMIT * 2])
            .is_none());
        assert!(parser.pending.is_empty());
        assert!(parser.consume(b"\nProgress: x: publishing\n").is_some());
        for unit in [
            "file", "page", "sheet", "frame", "slide", "chapter", "cell", "message", "note",
        ] {
            assert!(parser
                .consume(format!("Progress: x: converting {unit} 1/2\n").as_bytes())
                .unwrap()
                .counts
                .is_some());
        }
    }
}
