//! Exakte Ganzzahlwerte aus JSON-Zahltexten; kein Umweg über eine gerundete f64-Zahl.
use serde::{de::Error, Deserialize, Deserializer};
use serde_json::value::RawValue;

struct Integer {
    negative: bool,
    magnitude: u64,
    decimal: bool,
}
fn parse(raw: &str) -> Option<Integer> {
    let raw = raw.trim();
    let (negative, body) = raw.strip_prefix('-').map_or((false, raw), |s| (true, s));
    if !body.as_bytes().first()?.is_ascii_digit() {
        return None;
    }
    let exponent_at = body.find(['e', 'E']);
    let (mantissa, exponent) =
        exponent_at.map_or((body, None), |i| (&body[..i], Some(&body[i + 1..])));
    let fraction = mantissa.find('.').map_or(0, |i| mantissa.len() - i - 1);
    let digits: Vec<_> = mantissa.bytes().filter(|b| *b != b'.').collect();
    if !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let first = digits.iter().position(|b| *b != b'0');
    let decimal = fraction != 0 || exponent.is_some();
    let Some(first) = first else {
        return Some(Integer {
            negative,
            magnitude: 0,
            decimal,
        });
    };
    let last = digits.iter().rposition(|b| *b != b'0')?;
    let trailing = digits.len() - last - 1;
    // Ein überlaufender Exponent kann in einer begrenzten Nachricht keine
    // 64-Bit-Ganzzahl ergeben. Der exakte Nullfall wurde schon getrennt.
    let exponent = if let Some(text) = exponent {
        let (minus, text) = text.strip_prefix('-').map_or_else(
            || (false, text.strip_prefix('+').unwrap_or(text)),
            |s| (true, s),
        );
        let mut value = 0i64;
        for byte in text.bytes() {
            if !byte.is_ascii_digit() {
                return None;
            }
            value = value.checked_mul(10)?.checked_add(i64::from(byte - b'0'))?;
        }
        if minus {
            -value
        } else {
            value
        }
    } else {
        0
    };
    let shift = exponent
        .checked_sub(fraction as i64)?
        .checked_add(trailing as i64)?;
    if !(0..=20).contains(&shift) || (last - first + 1) as i64 + shift > 20 {
        return None;
    }
    let mut magnitude = 0u64;
    for byte in &digits[first..=last] {
        magnitude = magnitude
            .checked_mul(10)?
            .checked_add(u64::from(byte - b'0'))?;
    }
    for _ in 0..shift {
        magnitude = magnitude.checked_mul(10)?;
    }
    Some(Integer {
        negative,
        magnitude,
        decimal,
    })
}
impl Integer {
    fn signed(self) -> Option<i64> {
        if self.negative {
            if self.magnitude == 1u64 << 63 {
                return (!self.decimal).then_some(i64::MIN);
            }
            i64::try_from(self.magnitude).ok().map(|n| -n)
        } else {
            // Native Foundation verweigert Dezimal-/Exponentformen ab 2^63−512,
            // direkte Int64-Werte dagegen erst oberhalb MAX. Die Oraclefixture
            // hält diese Grenze fest; der Nutzwert wird trotzdem exakt berechnet.
            if self.decimal && self.magnitude > i64::MAX as u64 - 512 {
                return None;
            }
            i64::try_from(self.magnitude).ok()
        }
    }
    fn unsigned(self) -> Option<u64> {
        if self.negative && self.magnitude != 0 {
            return None;
        }
        // Entsprechende native UInt64-Grenze: 2^64−1024 wird dezimal verweigert.
        if self.decimal && self.magnitude > u64::MAX - 1024 {
            return None;
        }
        Some(self.magnitude)
    }
}
fn integer<'de, D: Deserializer<'de>>(d: D) -> Result<Integer, D::Error> {
    let raw = Box::<RawValue>::deserialize(d)?;
    parse(raw.get()).ok_or_else(|| D::Error::custom("expected an exact integer JSON number"))
}
pub(crate) fn i64<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    integer(d)?
        .signed()
        .ok_or_else(|| D::Error::custom("integer outside supported Int64 range"))
}
pub(crate) fn u64<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    integer(d)?
        .unsigned()
        .ok_or_else(|| D::Error::custom("integer outside supported UInt64 range"))
}
pub(crate) fn usize<'de, D: Deserializer<'de>>(d: D) -> Result<usize, D::Error> {
    usize::try_from(i64(d)?).map_err(|_| D::Error::custom("expected nonnegative Int64"))
}
pub(crate) fn optional_i64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    i64(d).map(Some)
}
pub(crate) fn non_null<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    d: D,
) -> Result<Option<T>, D::Error> {
    T::deserialize(d).map(Some)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Deserialize)]
    struct Signed {
        #[serde(deserialize_with = "i64")]
        value: i64,
    }
    #[derive(Deserialize)]
    struct Unsigned {
        #[serde(deserialize_with = "u64")]
        value: u64,
    }
    #[derive(Deserialize)]
    struct Small {
        #[serde(deserialize_with = "small")]
        value: u32,
    }
    fn small<'de, D: Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
        u32::try_from(u64(d)?).map_err(D::Error::custom)
    }
    #[derive(Deserialize)]
    struct Row {
        raw: String,
        int64: Option<String>,
        uint64: Option<String>,
        uint32: Option<String>,
    }
    #[test]
    fn native_foundation_whole_number_forms_and_explicit_fraction_refusals() {
        let fixtures = [
            include_str!("../tests/fixtures/control-integer-boundaries-macos.json"),
            include_str!("../tests/fixtures/control-integer-edges-macos.json"),
        ];
        let mut count = 0;
        for fixture in fixtures {
            for row in serde_json::from_str::<Vec<Row>>(fixture).unwrap() {
                let json = format!("{{\"value\":{}}}", row.raw);
                let signed = serde_json::from_str::<Signed>(&json)
                    .ok()
                    .map(|v| v.value.to_string());
                let unsigned = serde_json::from_str::<Unsigned>(&json)
                    .ok()
                    .map(|v| v.value.to_string());
                let small = serde_json::from_str::<Small>(&json)
                    .ok()
                    .map(|v| v.value.to_string());
                if matches!(
                    row.raw.as_str(),
                    "1.00000000000000000000000000001" | "1e-100000" | "9007199254740993.1"
                ) {
                    // Diese Foundation-Rundungen sind keine mathematischen Ganzzahlen.
                    assert!(signed.is_none() && unsigned.is_none() && small.is_none());
                } else {
                    assert_eq!(signed, row.int64, "Int64 {}", row.raw);
                    assert_eq!(unsigned, row.uint64, "UInt64 {}", row.raw);
                    assert_eq!(small, row.uint32, "UInt32 {}", row.raw);
                }
                count += 1;
            }
        }
        assert_eq!(count, 80);
    }
    #[test]
    fn values_and_null_do_not_become_numbers() {
        for raw in ["null", "true", "false", "\"1\"", "[]", "{}", "1.1", "1e-1"] {
            let json = format!("{{\"value\":{raw}}}");
            assert!(serde_json::from_str::<Signed>(&json).is_err(), "{raw}");
        }
    }
}
