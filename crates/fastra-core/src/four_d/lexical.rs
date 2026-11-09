use super::{check, Mask, Result};
use crate::Cancellation;
// Die Analysis bewahrt Mehrzeilen-Strings; der originale Swift-Tokenizer bricht an LF ab.
#[derive(Clone, Copy)]
pub(super) enum StringPolicy {
    Multiline,
    UntilLf,
}
pub(super) fn mask(
    source: &str,
    strings: StringPolicy,
    cancel: &Cancellation,
) -> Result<Vec<Mask>> {
    let bytes = source.as_bytes();
    let mut mask = vec![Mask::Code; bytes.len()];
    let mut i = 0;
    while i < bytes.len() {
        if i & 1023 == 0 {
            check(cancel)?;
        }
        let start = i;
        let kind = if bytes[i..].starts_with(b"//") {
            i += 2;
            while i < bytes.len() && !matches!(bytes[i], b'\r' | b'\n') {
                if i & 1023 == 0 {
                    check(cancel)?;
                }
                i += 1;
            }
            Some(Mask::Comment)
        } else if bytes[i..].starts_with(b"/*") {
            i += 2;
            while i < bytes.len() && !bytes[i..].starts_with(b"*/") {
                if i & 1023 == 0 {
                    check(cancel)?;
                }
                i += 1;
            }
            i = (i + 2).min(bytes.len());
            Some(Mask::Comment)
        } else if bytes[i] == b'"' {
            i += 1;
            while i < bytes.len() {
                if i & 1023 == 0 {
                    check(cancel)?;
                }
                let c = bytes[i];
                if c == b'\\' {
                    i = (i + 2).min(bytes.len());
                    continue;
                }
                i += 1;
                if c == b'"' || (c == b'\n' && matches!(strings, StringPolicy::UntilLf)) {
                    break;
                }
            }
            Some(Mask::String)
        } else {
            i += 1;
            None
        };
        if let Some(kind) = kind {
            mask[start..i].fill(kind);
        }
    }
    check(cancel)?;
    Ok(mask)
}
