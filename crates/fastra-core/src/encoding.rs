//! Strenge, verlustfreie Dateicodecs; eine BOM wird genau einmal abgetrennt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
    Windows1252,
    Latin1,
    MacRoman,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EncodingError {
    Malformed,
    Unrepresentable(char),
    Binary,
}
impl std::fmt::Display for EncodingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for EncodingError {}
type Result<T> = std::result::Result<T, EncodingError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decoded {
    text: String,
    encoding: Encoding,
    bom: Vec<u8>,
}
impl Decoded {
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn encoding(&self) -> Encoding {
        self.encoding
    }
    pub fn bom(&self) -> &[u8] {
        &self.bom
    }
    pub fn encode(&self, text: &str) -> Result<Vec<u8>> {
        let mut bytes = self.bom.clone();
        bytes.extend(encode_payload(text, self.encoding)?);
        Ok(bytes)
    }
}

pub fn detect_bom(bytes: &[u8]) -> (&[u8], Option<Encoding>) {
    for (bom, encoding) in [
        (&b"\0\0\xfe\xff"[..], Encoding::Utf32Be),
        (&b"\xff\xfe\0\0"[..], Encoding::Utf32Le),
        (&b"\xef\xbb\xbf"[..], Encoding::Utf8),
        (&b"\xfe\xff"[..], Encoding::Utf16Be),
        (&b"\xff\xfe"[..], Encoding::Utf16Le),
    ] {
        if bytes.starts_with(bom) {
            return (&bytes[..bom.len()], Some(encoding));
        }
    }
    (&bytes[..0], None)
}

pub fn decode(bytes: &[u8], explicit: Option<Encoding>) -> Result<Decoded> {
    let (bom, detected) = detect_bom(bytes);
    let payload = &bytes[bom.len()..];
    let (text, encoding) = if let Some(encoding) = explicit {
        (decode_payload(payload, encoding)?, encoding)
    } else {
        if payload.contains(&0)
            && !matches!(
                detected,
                Some(Encoding::Utf16Le | Encoding::Utf16Be | Encoding::Utf32Le | Encoding::Utf32Be)
            )
        {
            return Err(EncodingError::Binary);
        }
        if let Some(encoding) = detected {
            (decode_payload(payload, encoding)?, encoding)
        } else if let Ok(text) = decode_payload(payload, Encoding::Utf8) {
            (text, Encoding::Utf8)
        } else if payload
            .iter()
            .any(|&b| (0x80..=0x9f).contains(&b) && CP1252[(b - 128) as usize] != u32::MAX)
        {
            match decode_payload(payload, Encoding::Windows1252) {
                Ok(text) => (text, Encoding::Windows1252),
                Err(_) => (decode_payload(payload, Encoding::Latin1)?, Encoding::Latin1),
            }
        } else {
            (decode_payload(payload, Encoding::Latin1)?, Encoding::Latin1)
        }
    };
    Ok(Decoded {
        text,
        encoding,
        bom: bom.to_vec(),
    })
}

/// Dekodiert einen bereits ausgerichteten Abschnitt, ohne eine Inhalts-BOM zu entfernen.
pub fn decode_payload(bytes: &[u8], encoding: Encoding) -> Result<String> {
    match encoding {
        Encoding::Utf8 => std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|_| EncodingError::Malformed),
        Encoding::Utf16Le | Encoding::Utf16Be => {
            if bytes.len() % 2 != 0 {
                return Err(EncodingError::Malformed);
            }
            let units = bytes.chunks_exact(2).map(|b| {
                if encoding == Encoding::Utf16Le {
                    u16::from_le_bytes([b[0], b[1]])
                } else {
                    u16::from_be_bytes([b[0], b[1]])
                }
            });
            char::decode_utf16(units)
                .map(|c| c.map_err(|_| EncodingError::Malformed))
                .collect()
        }
        Encoding::Utf32Le | Encoding::Utf32Be => {
            if bytes.len() % 4 != 0 {
                return Err(EncodingError::Malformed);
            }
            bytes
                .chunks_exact(4)
                .map(|b| {
                    let b: [u8; 4] = b.try_into().unwrap();
                    let unit = if encoding == Encoding::Utf32Le {
                        u32::from_le_bytes(b)
                    } else {
                        u32::from_be_bytes(b)
                    };
                    char::from_u32(unit).ok_or(EncodingError::Malformed)
                })
                .collect()
        }
        _ => bytes
            .iter()
            .map(|&byte| {
                let unit = if byte < 128 || encoding == Encoding::Latin1 {
                    byte as u32
                } else if encoding == Encoding::Windows1252 {
                    CP1252[(byte - 128) as usize]
                } else {
                    MAC_ROMAN[(byte - 128) as usize]
                };
                char::from_u32(unit).ok_or(EncodingError::Malformed)
            })
            .collect(),
    }
}

fn encode_payload(text: &str, encoding: Encoding) -> Result<Vec<u8>> {
    let mut result = Vec::new();
    match encoding {
        Encoding::Utf8 => result.extend_from_slice(text.as_bytes()),
        Encoding::Utf16Le | Encoding::Utf16Be => {
            for unit in text.encode_utf16() {
                result.extend_from_slice(&if encoding == Encoding::Utf16Le {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
        }
        Encoding::Utf32Le | Encoding::Utf32Be => {
            for c in text.chars() {
                result.extend_from_slice(&if encoding == Encoding::Utf32Le {
                    (c as u32).to_le_bytes()
                } else {
                    (c as u32).to_be_bytes()
                });
            }
        }
        _ => {
            for c in text.chars() {
                let unit = c as u32;
                let byte = if unit < 128 || (encoding == Encoding::Latin1 && unit <= 255) {
                    Some(unit as u8)
                } else if encoding == Encoding::Latin1 {
                    None
                } else {
                    let table = if encoding == Encoding::Windows1252 {
                        &CP1252
                    } else {
                        &MAC_ROMAN
                    };
                    table
                        .iter()
                        .position(|&v| v == unit)
                        .map(|i| (i + 128) as u8)
                };
                result.push(byte.ok_or(EncodingError::Unrepresentable(c))?);
            }
        }
    }
    Ok(result)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    Lf,
    CrLf,
    Cr,
}
impl LineEnding {
    pub fn detect(text: &str) -> Self {
        if text.contains("\r\n") {
            Self::CrLf
        } else if text.contains('\r') {
            Self::Cr
        } else {
            Self::Lf
        }
    }
    pub fn convert(self, text: &str) -> String {
        let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
        match self {
            Self::Lf => normalized,
            Self::CrLf => normalized.replace('\n', "\r\n"),
            Self::Cr => normalized.replace('\n', "\r"),
        }
    }
}
const CP1252: [u32; 128] = [
    0x20ac, 0xffffffff, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160,
    0x2039, 0x0152, 0xffffffff, 0x017d, 0xffffffff, 0xffffffff, 0x2018, 0x2019, 0x201c, 0x201d,
    0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0xffffffff, 0x017e, 0x0178,
    0x00a0, 0x00a1, 0x00a2, 0x00a3, 0x00a4, 0x00a5, 0x00a6, 0x00a7, 0x00a8, 0x00a9, 0x00aa, 0x00ab,
    0x00ac, 0x00ad, 0x00ae, 0x00af, 0x00b0, 0x00b1, 0x00b2, 0x00b3, 0x00b4, 0x00b5, 0x00b6, 0x00b7,
    0x00b8, 0x00b9, 0x00ba, 0x00bb, 0x00bc, 0x00bd, 0x00be, 0x00bf, 0x00c0, 0x00c1, 0x00c2, 0x00c3,
    0x00c4, 0x00c5, 0x00c6, 0x00c7, 0x00c8, 0x00c9, 0x00ca, 0x00cb, 0x00cc, 0x00cd, 0x00ce, 0x00cf,
    0x00d0, 0x00d1, 0x00d2, 0x00d3, 0x00d4, 0x00d5, 0x00d6, 0x00d7, 0x00d8, 0x00d9, 0x00da, 0x00db,
    0x00dc, 0x00dd, 0x00de, 0x00df, 0x00e0, 0x00e1, 0x00e2, 0x00e3, 0x00e4, 0x00e5, 0x00e6, 0x00e7,
    0x00e8, 0x00e9, 0x00ea, 0x00eb, 0x00ec, 0x00ed, 0x00ee, 0x00ef, 0x00f0, 0x00f1, 0x00f2, 0x00f3,
    0x00f4, 0x00f5, 0x00f6, 0x00f7, 0x00f8, 0x00f9, 0x00fa, 0x00fb, 0x00fc, 0x00fd, 0x00fe, 0x00ff,
];

const MAC_ROMAN: [u32; 128] = [
    0x00c4, 0x00c5, 0x00c7, 0x00c9, 0x00d1, 0x00d6, 0x00dc, 0x00e1, 0x00e0, 0x00e2, 0x00e4, 0x00e3,
    0x00e5, 0x00e7, 0x00e9, 0x00e8, 0x00ea, 0x00eb, 0x00ed, 0x00ec, 0x00ee, 0x00ef, 0x00f1, 0x00f3,
    0x00f2, 0x00f4, 0x00f6, 0x00f5, 0x00fa, 0x00f9, 0x00fb, 0x00fc, 0x2020, 0x00b0, 0x00a2, 0x00a3,
    0x00a7, 0x2022, 0x00b6, 0x00df, 0x00ae, 0x00a9, 0x2122, 0x00b4, 0x00a8, 0x2260, 0x00c6, 0x00d8,
    0x221e, 0x00b1, 0x2264, 0x2265, 0x00a5, 0x00b5, 0x2202, 0x2211, 0x220f, 0x03c0, 0x222b, 0x00aa,
    0x00ba, 0x03a9, 0x00e6, 0x00f8, 0x00bf, 0x00a1, 0x00ac, 0x221a, 0x0192, 0x2248, 0x2206, 0x00ab,
    0x00bb, 0x2026, 0x00a0, 0x00c0, 0x00c3, 0x00d5, 0x0152, 0x0153, 0x2013, 0x2014, 0x201c, 0x201d,
    0x2018, 0x2019, 0x00f7, 0x25ca, 0x00ff, 0x0178, 0x2044, 0x20ac, 0x2039, 0x203a, 0xfb01, 0xfb02,
    0x2021, 0x00b7, 0x201a, 0x201e, 0x2030, 0x00c2, 0x00ca, 0x00c1, 0x00cb, 0x00c8, 0x00cd, 0x00ce,
    0x00cf, 0x00cc, 0x00d3, 0x00d4, 0xf8ff, 0x00d2, 0x00da, 0x00db, 0x00d9, 0x0131, 0x02c6, 0x02dc,
    0x00af, 0x02d8, 0x02d9, 0x02da, 0x00b8, 0x02dd, 0x02db, 0x02c7,
];
