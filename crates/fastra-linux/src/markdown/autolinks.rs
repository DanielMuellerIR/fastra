//! GFM-Atome aus dem gepinnten Parser; alle Text-/Quellgrenzen sind registriert.
use super::math::{Budget, Error, Extraction};
use fastra_core::Cancellation;
use std::{
    ffi::c_void,
    ops::Range,
    sync::{Mutex, TryLockError},
    time::Duration,
};
#[derive(Clone, Debug)]
pub(super) struct Link {
    pub range: Range<usize>,
    pub url: String,
    pub text: String,
}
#[repr(C)]
struct RawSpan {
    lo: usize,
    hi: usize,
    source_lo: usize,
    source_hi: usize,
    identity: i32,
}
#[repr(C)]
struct RawAtom {
    start: usize,
    end: usize,
    origin: i32,
    url: *mut u8,
    text: *mut u8,
    url_length: usize,
    text_length: usize,
    spans: *mut RawSpan,
    span_count: usize,
}
#[repr(C)]
struct RawPlan {
    atoms: *mut RawAtom,
    count: usize,
}
unsafe extern "C" {
    fn fastra_plan_parse(
        source: *const u8,
        length: usize,
        cancelled: extern "C" fn(*mut c_void) -> i32,
        context: *mut c_void,
        out: *mut RawPlan,
    ) -> i32;
    fn fastra_plan_free(plan: *mut RawPlan);
}
impl Drop for RawPlan {
    fn drop(&mut self) {
        unsafe { fastra_plan_free(self) }
    }
}
static PARSER: Mutex<()> = Mutex::new(());
extern "C" fn cancelled(context: *mut c_void) -> i32 {
    i32::from(
        unsafe { &*(context as *const Cancellation) }
            .check()
            .is_err(),
    )
}
// Diese notwendige Vorbedingung ist keine Linkerkennung: HTTP/www brauchen
// rohe Marker, dekodierte Mailadressen mindestens @ oder eine Entity.
pub(crate) fn may_link(source: &str) -> bool {
    source.contains("://") || source.contains("www.") || source.contains('@') || source.contains('&')
}
pub(super) fn scan(extraction: &Extraction, cancel: &Cancellation) -> Result<Vec<Link>, Error> {
    cancel.check()?;
    let budget = Budget::default();
    let source = extraction.prepared();
    if !may_link(source) { return Ok(Vec::new()); }
    if source.len() > budget.view_bytes {
        return Err(Error::Limit);
    }
    let _guard = loop {
        match PARSER.try_lock() {
            Ok(g) => break g,
            Err(TryLockError::WouldBlock) => {
                cancel.check()?;
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(TryLockError::Poisoned(_)) => return Err(Error::Invariant),
        }
    };
    let mut raw = RawPlan {
        atoms: std::ptr::null_mut(),
        count: 0,
    };
    match unsafe {
        fastra_plan_parse(
            source.as_ptr(),
            source.len(),
            cancelled,
            cancel as *const Cancellation as *mut c_void,
            &mut raw,
        )
    } {
        0 => {}
        1 => return Err(Error::Core(fastra_core::Error::Cancelled)),
        2 => return Err(Error::Limit),
        _ => return Err(Error::Boundary),
    }
    if raw.count > budget.matches || (raw.count > 0 && raw.atoms.is_null()) {
        return Err(Error::Invariant);
    }
    let atoms = if raw.count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(raw.atoms, raw.count) }
    };
    let mut result = Vec::with_capacity(atoms.len());
    let mut bytes = 0usize;
    let mut restored_bytes = 0usize;
    for atom in atoms {
        cancel.check()?;
        let range = atom.start..atom.end;
        if range.start >= range.end
            || range.end > source.len()
            || !source.is_char_boundary(range.start)
            || !source.is_char_boundary(range.end)
            || atom.url.is_null()
            || atom.text.is_null()
            || (atom.span_count > 0 && atom.spans.is_null())
        {
            return Err(Error::Boundary);
        }
        extraction.original_range(range.clone())?;
        bytes = bytes
            .checked_add(atom.url_length)
            .and_then(|n| n.checked_add(atom.text_length))
            .and_then(|n| {
                n.checked_add(
                    atom.span_count
                        .checked_mul(std::mem::size_of::<RawSpan>())?,
                )
            })
            .ok_or(Error::Limit)?;
        if bytes > budget.view_bytes {
            return Err(Error::Limit);
        }
        let text =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(atom.text, atom.text_length) })
                .map_err(|_| Error::Boundary)?;
        let url =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(atom.url, atom.url_length) })
                .map_err(|_| Error::Boundary)?;
        let spans = if atom.span_count == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(atom.spans, atom.span_count) }
        };
        let mut cursor = 0;
        let mut source_cursor = 0;
        for span in spans {
            if span.source_lo < source_cursor
                || span.lo != cursor
                || span.hi < span.lo
                || span.hi > text.len()
                || span.source_lo > span.source_hi
                || span.source_hi > source.len()
                || (span.identity != 0
                    && (span.hi - span.lo != span.source_hi - span.source_lo
                        || text.as_bytes()[span.lo..span.hi]
                            != source.as_bytes()[span.source_lo..span.source_hi]))
            {
                return Err(Error::Boundary);
            }
            cursor = span.hi;
            source_cursor = span.source_hi;
        }
        if cursor != text.len() {
            return Err(Error::Boundary);
        }
        let first = extraction
            .tokens()
            .partition_point(|token| token.prepared.end <= range.start);
        let mut changes = Vec::new();
        for token in extraction.tokens()[first..]
            .iter()
            .take_while(|token| token.prepared.start < range.end)
        {
            cancel.check()?;
            if token.prepared.start < range.start || token.prepared.end > range.end {
                return Err(Error::Boundary);
            }
            // Nur eine identische, positionsbelegte Textspanne darf ein Mathatom
            // zurückführen. Im URI wird ausschließlich dessen roher Quelltext eingesetzt.
            let index = spans.partition_point(|span| span.source_hi <= token.prepared.start);
            let span = spans
                .get(index)
                .filter(|span| {
                    span.identity != 0
                        && span.source_lo <= token.prepared.start
                        && span.source_hi >= token.prepared.end
                })
                .ok_or(Error::Boundary)?;
            let start = span.lo + token.prepared.start - span.source_lo;
            let end = start + token.prepared.len();
            if !text.is_char_boundary(start)
                || !text.is_char_boundary(end)
                || text[start..end] != source[token.prepared.clone()]
            {
                return Err(Error::Boundary);
            }
            let formula = &extraction.formulas()[token.formula];
            changes.push((
                start..end,
                extraction.source()[formula.source.bytes.clone()].to_owned(),
            ));
        }
        let prefix = url.strip_suffix(text).ok_or(Error::Boundary)?;
        if !matches!(
            (atom.origin, prefix),
            (1, "") | (2, "http://") | (3, "") | (3, "mailto:")
        ) {
            return Err(Error::Boundary);
        }
        let mut restored = String::new();
        let mut at = 0;
        for (range, original) in changes {
            if range.start < at {
                return Err(Error::Boundary);
            }
            restored.push_str(&text[at..range.start]);
            restored.push_str(&original);
            at = range.end;
        }
        restored.push_str(&text[at..]);
        restored_bytes = restored_bytes
            .checked_add(restored.len())
            .and_then(|n| n.checked_add(restored.len()))
            .and_then(|n| n.checked_add(prefix.len()))
            .ok_or(Error::Limit)?;
        if restored_bytes > budget.view_bytes {
            return Err(Error::Limit);
        }
        result.push(Link {
            range,
            url: format!("{prefix}{restored}"),
            text: restored,
        });
    }
    result.sort_by_key(|link| link.range.start);
    if result
        .windows(2)
        .any(|pair| pair[0].range.end > pair[1].range.start)
    {
        return Err(Error::Boundary);
    }
    Ok(result)
}

#[cfg(test)]
mod native_limits {
    use super::*;
    #[test]
    fn cooperative_midparse_cancel_frees_all_segments_and_atoms() {
        struct State {
            checks: usize,
        }
        extern "C" fn stop(context: *mut c_void) -> i32 {
            let state = unsafe { &mut *(context as *mut State) };
            state.checks += 1;
            i32::from(state.checks >= 1000)
        }
        let _guard = PARSER.lock().unwrap();
        let source = "a&#64;example.com ".repeat(10000);
        let mut state = State { checks: 0 };
        let mut raw = RawPlan {
            atoms: std::ptr::null_mut(),
            count: 0,
        };
        let status = unsafe {
            fastra_plan_parse(
                source.as_ptr(),
                source.len(),
                stop,
                &mut state as *mut State as *mut c_void,
                &mut raw,
            )
        };
        assert_eq!(status, 1);
        assert_eq!(state.checks, 1000);
        assert_eq!(raw.count, 0);
        assert!(raw.atoms.is_null());
    }
    #[test]
    fn native_work_limit_does_not_return_a_partial_atom_plan() {
        let source = "&amp;".repeat(300000);
        let cancel = Cancellation::default();
        let extraction =
            super::super::math::normalized(&source, Budget::default(), &cancel).unwrap();
        assert!(matches!(scan(&extraction, &cancel), Err(Error::Limit)));
    }
}
