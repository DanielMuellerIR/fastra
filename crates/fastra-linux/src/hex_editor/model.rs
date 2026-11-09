//! Reines, begrenztes Hex-Modell; Dateisnapshot, Save und Owner-Generation gehören zum Host.
use std::{collections::BTreeMap, sync::Arc};

const MAX_SOURCE: usize = 32 * 1024 * 1024;
const MAX_CHANGES: usize = 4096;
const MAX_HISTORY: usize = 4096;
const MAX_ROW_TEXT: usize = 4096;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub offset: usize,
    pub old: u8,
    pub new: u8,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Limit,
    InvalidRow,
    InvalidOffset,
    Stale,
}
struct Action {
    before: Vec<(usize, Option<Change>)>,
    after: Vec<(usize, Option<Change>)>,
}
pub struct Session {
    source: Arc<[u8]>,
    changes: BTreeMap<usize, Change>,
    undo: Vec<Action>,
    redo: Vec<Action>,
    revision: u64,
}
#[derive(Clone)]
pub struct Frozen {
    source: Arc<[u8]>,
    changes: Vec<Change>,
    revision: u64,
}
impl Frozen {
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn changes(&self) -> &[Change] {
        &self.changes
    }
    pub fn output(&self) -> Result<Vec<u8>, Error> {
        let mut output = self.source.to_vec();
        for change in &self.changes {
            if output.get(change.offset) != Some(&change.old) {
                return Err(Error::Stale);
            }
            output[change.offset] = change.new;
        }
        Ok(output)
    }
}
fn whitespace(c: char) -> bool {
    matches!(c,'\t'..='\r'|' '|'\u{85}'|'\u{a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'..='\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}')
}
fn extends_whitespace(c: char) -> bool {
    let value = c as u32;
    let index = WHITESPACE_SUFFIX_RANGES.partition_point(|&(_, end)| end < value);
    WHITESPACE_SUFFIX_RANGES
        .get(index)
        .is_some_and(|&(start, _)| start <= value)
}
fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}
fn byte_token(token: &str) -> Result<u8, Error> {
    // UInt8(..., radix:16) akzeptiert im Swift-Original auch diese Zweizeichen-Tokens.
    match token.as_bytes() {
        [b'+', value] => hex(*value).ok_or(Error::InvalidRow),
        [b'-', b'0'] => Ok(0),
        [high, low] => {
            Ok(hex(*high).ok_or(Error::InvalidRow)? * 16 + hex(*low).ok_or(Error::InvalidRow)?)
        }
        _ => Err(Error::InvalidRow),
    }
}
pub fn parse_row(text: &str, expected: usize) -> Result<Vec<u8>, Error> {
    if text.len() > MAX_ROW_TEXT {
        return Err(Error::Limit);
    }
    let mut values = Vec::with_capacity(expected.min(16));
    let mut start = None;
    let mut suffix = false;
    for (index, c) in text.char_indices() {
        if whitespace(c) {
            if let Some(begin) = start.take() {
                values.push(byte_token(&text[begin..index])?);
                if values.len() > expected {
                    return Err(Error::InvalidRow);
                }
            }
            // Swift wertet den gesamten Graphemcluster nach dessen erstem Skalar.
            // Control-Whitespace bricht vor kombinierenden Folgezeichen, andere Spaces nicht.
            suffix = !matches!(c, '\t'..='\r' | '\u{85}' | '\u{2028}' | '\u{2029}');
        } else if !(suffix && extends_whitespace(c)) {
            suffix = false;
            start.get_or_insert(index);
        }
    }
    if let Some(begin) = start {
        values.push(byte_token(&text[begin..])?);
    }
    if values.len() != expected {
        return Err(Error::InvalidRow);
    }
    Ok(values)
}
impl Session {
    pub fn new(source: Arc<[u8]>) -> Result<Self, Error> {
        if source.len() > MAX_SOURCE {
            return Err(Error::Limit);
        }
        Ok(Self {
            source,
            changes: BTreeMap::new(),
            undo: Vec::new(),
            redo: Vec::new(),
            revision: 0,
        })
    }
    pub fn source(&self) -> &[u8] {
        &self.source
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn changes(&self) -> Vec<Change> {
        self.changes.values().cloned().collect()
    }
    pub fn dirty(&self) -> bool {
        !self.changes.is_empty()
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
    pub fn page(&self, offset: usize, length: usize) -> Result<Vec<u8>, Error> {
        if offset > self.source.len() || length > 4096 {
            return Err(Error::InvalidOffset);
        }
        let end = offset.saturating_add(length).min(self.source.len());
        let mut page = self.source[offset..end].to_vec();
        for (&index, change) in self.changes.range(offset..end) {
            page[index - offset] = change.new;
        }
        Ok(page)
    }
    pub fn row(&self, offset: usize) -> Result<String, Error> {
        if offset >= self.source.len() || !offset.is_multiple_of(16) {
            return Err(Error::InvalidOffset);
        }
        Ok(self
            .page(offset, 16)?
            .iter()
            .map(|value| format!("{value:02X}"))
            .collect::<Vec<_>>()
            .join(" "))
    }
    pub fn edit_row(&mut self, offset: usize, text: &str) -> Result<bool, Error> {
        if offset >= self.source.len() || !offset.is_multiple_of(16) {
            return Err(Error::InvalidOffset);
        }
        let end = (offset + 16).min(self.source.len());
        let values = parse_row(text, end - offset)?;
        let before = (offset..end)
            .map(|index| (index, self.changes.get(&index).cloned()))
            .collect::<Vec<_>>();
        let after = values
            .iter()
            .enumerate()
            .map(|(relative, &new)| {
                let index = offset + relative;
                (
                    index,
                    (new != self.source[index]).then_some(Change {
                        offset: index,
                        old: self.source[index],
                        new,
                    }),
                )
            })
            .collect::<Vec<_>>();
        if before == after {
            return Ok(false);
        }
        let count = self.changes.len()
            - before.iter().filter(|(_, change)| change.is_some()).count()
            + after.iter().filter(|(_, change)| change.is_some()).count();
        if count > MAX_CHANGES || self.undo.len() >= MAX_HISTORY {
            return Err(Error::Limit);
        }
        self.install(&after);
        self.undo.push(Action { before, after });
        self.redo.clear();
        self.revision = self.revision.wrapping_add(1);
        Ok(true)
    }
    fn install(&mut self, values: &[(usize, Option<Change>)]) {
        for (index, value) in values {
            if let Some(value) = value {
                self.changes.insert(*index, value.clone());
            } else {
                self.changes.remove(index);
            }
        }
    }
    pub fn undo(&mut self) -> bool {
        let Some(action) = self.undo.pop() else {
            return false;
        };
        self.install(&action.before);
        self.redo.push(action);
        self.revision = self.revision.wrapping_add(1);
        true
    }
    pub fn redo(&mut self) -> bool {
        let Some(action) = self.redo.pop() else {
            return false;
        };
        self.install(&action.after);
        self.undo.push(action);
        self.revision = self.revision.wrapping_add(1);
        true
    }
    pub fn frozen(&self, revision: u64) -> Result<Frozen, Error> {
        if revision != self.revision {
            return Err(Error::Stale);
        }
        Ok(Frozen {
            source: self.source.clone(),
            changes: self.changes(),
            revision,
        })
    }
    // Der GUI-Host verwendet frozen() auf GtkMain und führt output() auf dem Worker aus.
    #[cfg(test)]
    pub fn output(&self, revision: u64) -> Result<Vec<u8>, Error> {
        self.frozen(revision)?.output()
    }
}

// Aus dem vollständigen Swift-6.2.1-Skalar-Oracle erzeugt; siehe Hex-Referenzfixtures.
#[rustfmt::skip]
const WHITESPACE_SUFFIX_RANGES: &[(u32,u32)] = &[
    (0x300,0x36F),(0x483,0x489),(0x591,0x5BD),(0x5BF,0x5BF),
    (0x5C1,0x5C2),(0x5C4,0x5C5),(0x5C7,0x5C7),(0x610,0x61A),
    (0x64B,0x65F),(0x670,0x670),(0x6D6,0x6DC),(0x6DF,0x6E4),
    (0x6E7,0x6E8),(0x6EA,0x6ED),(0x711,0x711),(0x730,0x74A),
    (0x7A6,0x7B0),(0x7EB,0x7F3),(0x7FD,0x7FD),(0x816,0x819),
    (0x81B,0x823),(0x825,0x827),(0x829,0x82D),(0x859,0x85B),
    (0x897,0x89F),(0x8CA,0x8E1),(0x8E3,0x903),(0x93A,0x93C),
    (0x93E,0x94F),(0x951,0x957),(0x962,0x963),(0x981,0x983),
    (0x9BC,0x9BC),(0x9BE,0x9C4),(0x9C7,0x9C8),(0x9CB,0x9CD),
    (0x9D7,0x9D7),(0x9E2,0x9E3),(0x9FE,0x9FE),(0xA01,0xA03),
    (0xA3C,0xA3C),(0xA3E,0xA42),(0xA47,0xA48),(0xA4B,0xA4D),
    (0xA51,0xA51),(0xA70,0xA71),(0xA75,0xA75),(0xA81,0xA83),
    (0xABC,0xABC),(0xABE,0xAC5),(0xAC7,0xAC9),(0xACB,0xACD),
    (0xAE2,0xAE3),(0xAFA,0xAFF),(0xB01,0xB03),(0xB3C,0xB3C),
    (0xB3E,0xB44),(0xB47,0xB48),(0xB4B,0xB4D),(0xB55,0xB57),
    (0xB62,0xB63),(0xB82,0xB82),(0xBBE,0xBC2),(0xBC6,0xBC8),
    (0xBCA,0xBCD),(0xBD7,0xBD7),(0xC00,0xC04),(0xC3C,0xC3C),
    (0xC3E,0xC44),(0xC46,0xC48),(0xC4A,0xC4D),(0xC55,0xC56),
    (0xC62,0xC63),(0xC81,0xC83),(0xCBC,0xCBC),(0xCBE,0xCC4),
    (0xCC6,0xCC8),(0xCCA,0xCCD),(0xCD5,0xCD6),(0xCE2,0xCE3),
    (0xCF3,0xCF3),(0xD00,0xD03),(0xD3B,0xD3C),(0xD3E,0xD44),
    (0xD46,0xD48),(0xD4A,0xD4D),(0xD57,0xD57),(0xD62,0xD63),
    (0xD81,0xD83),(0xDCA,0xDCA),(0xDCF,0xDD4),(0xDD6,0xDD6),
    (0xDD8,0xDDF),(0xDF2,0xDF3),(0xE31,0xE31),(0xE33,0xE3A),
    (0xE47,0xE4E),(0xEB1,0xEB1),(0xEB3,0xEBC),(0xEC8,0xECE),
    (0xF18,0xF19),(0xF35,0xF35),(0xF37,0xF37),(0xF39,0xF39),
    (0xF3E,0xF3F),(0xF71,0xF84),(0xF86,0xF87),(0xF8D,0xF97),
    (0xF99,0xFBC),(0xFC6,0xFC6),(0x102D,0x1037),(0x1039,0x103E),
    (0x1056,0x1059),(0x105E,0x1060),(0x1071,0x1074),(0x1082,0x1082),
    (0x1084,0x1086),(0x108D,0x108D),(0x109D,0x109D),(0x135D,0x135F),
    (0x1712,0x1715),(0x1732,0x1734),(0x1752,0x1753),(0x1772,0x1773),
    (0x17B4,0x17D3),(0x17DD,0x17DD),(0x180B,0x180D),(0x180F,0x180F),
    (0x1885,0x1886),(0x18A9,0x18A9),(0x1920,0x192B),(0x1930,0x193B),
    (0x1A17,0x1A1B),(0x1A55,0x1A5E),(0x1A60,0x1A60),(0x1A62,0x1A62),
    (0x1A65,0x1A7C),(0x1A7F,0x1A7F),(0x1AB0,0x1ACE),(0x1B00,0x1B04),
    (0x1B34,0x1B44),(0x1B6B,0x1B73),(0x1B80,0x1B82),(0x1BA1,0x1BAD),
    (0x1BE6,0x1BF3),(0x1C24,0x1C37),(0x1CD0,0x1CD2),(0x1CD4,0x1CE8),
    (0x1CED,0x1CED),(0x1CF4,0x1CF4),(0x1CF7,0x1CF9),(0x1DC0,0x1DFF),
    (0x200C,0x200D),(0x20D0,0x20F0),(0x2CEF,0x2CF1),(0x2D7F,0x2D7F),
    (0x2DE0,0x2DFF),(0x302A,0x302F),(0x3099,0x309A),(0xA66F,0xA672),
    (0xA674,0xA67D),(0xA69E,0xA69F),(0xA6F0,0xA6F1),(0xA802,0xA802),
    (0xA806,0xA806),(0xA80B,0xA80B),(0xA823,0xA827),(0xA82C,0xA82C),
    (0xA880,0xA881),(0xA8B4,0xA8C5),(0xA8E0,0xA8F1),(0xA8FF,0xA8FF),
    (0xA926,0xA92D),(0xA947,0xA953),(0xA980,0xA983),(0xA9B3,0xA9C0),
    (0xA9E5,0xA9E5),(0xAA29,0xAA36),(0xAA43,0xAA43),(0xAA4C,0xAA4D),
    (0xAA7C,0xAA7C),(0xAAB0,0xAAB0),(0xAAB2,0xAAB4),(0xAAB7,0xAAB8),
    (0xAABE,0xAABF),(0xAAC1,0xAAC1),(0xAAEB,0xAAEF),(0xAAF5,0xAAF6),
    (0xABE3,0xABEA),(0xABEC,0xABED),(0xFB1E,0xFB1E),(0xFE00,0xFE0F),
    (0xFE20,0xFE2F),(0xFF9E,0xFF9F),(0x101FD,0x101FD),(0x102E0,0x102E0),
    (0x10376,0x1037A),(0x10A01,0x10A03),(0x10A05,0x10A06),(0x10A0C,0x10A0F),
    (0x10A38,0x10A3A),(0x10A3F,0x10A3F),(0x10AE5,0x10AE6),(0x10D24,0x10D27),
    (0x10D69,0x10D6D),(0x10EAB,0x10EAC),(0x10EFC,0x10EFF),(0x10F46,0x10F50),
    (0x10F82,0x10F85),(0x11000,0x11002),(0x11038,0x11046),(0x11070,0x11070),
    (0x11073,0x11074),(0x1107F,0x11082),(0x110B0,0x110BA),(0x110C2,0x110C2),
    (0x11100,0x11102),(0x11127,0x11134),(0x11145,0x11146),(0x11173,0x11173),
    (0x11180,0x11182),(0x111B3,0x111C0),(0x111C9,0x111CC),(0x111CE,0x111CF),
    (0x1122C,0x11237),(0x1123E,0x1123E),(0x11241,0x11241),(0x112DF,0x112EA),
    (0x11300,0x11303),(0x1133B,0x1133C),(0x1133E,0x11344),(0x11347,0x11348),
    (0x1134B,0x1134D),(0x11357,0x11357),(0x11362,0x11363),(0x11366,0x1136C),
    (0x11370,0x11374),(0x113B8,0x113C0),(0x113C2,0x113C2),(0x113C5,0x113C5),
    (0x113C7,0x113CA),(0x113CC,0x113D0),(0x113D2,0x113D2),(0x113E1,0x113E2),
    (0x11435,0x11446),(0x1145E,0x1145E),(0x114B0,0x114C3),(0x115AF,0x115B5),
    (0x115B8,0x115C0),(0x115DC,0x115DD),(0x11630,0x11640),(0x116AB,0x116B7),
    (0x1171D,0x1171F),(0x11722,0x1172B),(0x1182C,0x1183A),(0x11930,0x11935),
    (0x11937,0x11938),(0x1193B,0x1193E),(0x11940,0x11940),(0x11942,0x11943),
    (0x119D1,0x119D7),(0x119DA,0x119E0),(0x119E4,0x119E4),(0x11A01,0x11A0A),
    (0x11A33,0x11A39),(0x11A3B,0x11A3E),(0x11A47,0x11A47),(0x11A51,0x11A5B),
    (0x11A8A,0x11A99),(0x11C2F,0x11C36),(0x11C38,0x11C3F),(0x11C92,0x11CA7),
    (0x11CA9,0x11CB6),(0x11D31,0x11D36),(0x11D3A,0x11D3A),(0x11D3C,0x11D3D),
    (0x11D3F,0x11D45),(0x11D47,0x11D47),(0x11D8A,0x11D8E),(0x11D90,0x11D91),
    (0x11D93,0x11D97),(0x11EF3,0x11EF6),(0x11F00,0x11F01),(0x11F03,0x11F03),
    (0x11F34,0x11F3A),(0x11F3E,0x11F42),(0x11F5A,0x11F5A),(0x13440,0x13440),
    (0x13447,0x13455),(0x1611E,0x1612F),(0x16AF0,0x16AF4),(0x16B30,0x16B36),
    (0x16F4F,0x16F4F),(0x16F51,0x16F87),(0x16F8F,0x16F92),(0x16FE4,0x16FE4),
    (0x16FF0,0x16FF1),(0x1BC9D,0x1BC9E),(0x1CF00,0x1CF2D),(0x1CF30,0x1CF46),
    (0x1D165,0x1D169),(0x1D16D,0x1D172),(0x1D17B,0x1D182),(0x1D185,0x1D18B),
    (0x1D1AA,0x1D1AD),(0x1D242,0x1D244),(0x1DA00,0x1DA36),(0x1DA3B,0x1DA6C),
    (0x1DA75,0x1DA75),(0x1DA84,0x1DA84),(0x1DA9B,0x1DA9F),(0x1DAA1,0x1DAAF),
    (0x1E000,0x1E006),(0x1E008,0x1E018),(0x1E01B,0x1E021),(0x1E023,0x1E024),
    (0x1E026,0x1E02A),(0x1E08F,0x1E08F),(0x1E130,0x1E136),(0x1E2AE,0x1E2AE),
    (0x1E2EC,0x1E2EF),(0x1E4EC,0x1E4EF),(0x1E5EE,0x1E5EF),(0x1E8D0,0x1E8D6),
    (0x1E944,0x1E94A),(0x1F3FB,0x1F3FF),(0xE0020,0xE007F),(0xE0100,0xE01EF),
];

#[cfg(test)]
#[path = "model_tests.rs"]
mod tests;
