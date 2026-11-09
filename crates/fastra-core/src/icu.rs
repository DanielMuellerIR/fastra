use crate::{Cancellation, Error, Limits, Utf16Range};
use std::{
    ffi::{c_char, c_void},
    ptr::NonNull,
    sync::atomic::{AtomicBool, Ordering},
};

unsafe extern "C" {
    fn fastra_regex_open(
        p: *const u16,
        n: i32,
        flags: u32,
        offset: *mut i32,
        status: *mut i32,
    ) -> *mut c_void;
    fn fastra_regex_close(r: *mut c_void);
    fn fastra_regex_clone(r: *const c_void, status: *mut i32) -> *mut c_void;
    fn fastra_regex_text(r: *mut c_void, p: *const u16, n: i32, status: *mut i32);
    fn fastra_regex_limits(r: *mut c_void, time: i32, stack: i32, status: *mut i32);
    fn fastra_regex_callback(
        r: *mut c_void,
        callback: unsafe extern "C" fn(*const c_void, i32) -> i8,
        context: *const c_void,
        status: *mut i32,
    );
    fn fastra_regex_next(r: *mut c_void, status: *mut i32) -> i32;
    fn fastra_regex_groups(r: *mut c_void, status: *mut i32) -> i32;
    fn fastra_regex_start(r: *mut c_void, group: i32, status: *mut i32) -> i32;
    fn fastra_regex_end(r: *mut c_void, group: i32, status: *mut i32) -> i32;
    fn fastra_case(
        p: *const u16,
        n: i32,
        out: *mut u16,
        cap: i32,
        upper: i32,
        locale: *const c_char,
        status: *mut i32,
    ) -> i32;
    fn fastra_locale_known(locale: *const std::ffi::c_char) -> i32;
    fn fastra_titlecase(
        p: *const u16,
        n: i32,
        out: *mut u16,
        cap: i32,
        locale: *const std::ffi::c_char,
        status: *mut i32,
    ) -> i32;
    fn fastra_graphemes_open(p: *const u16, n: i32, status: *mut i32) -> *mut c_void;
    fn fastra_graphemes_next(iterator: *mut c_void) -> i32;
    fn fastra_graphemes_close(iterator: *mut c_void);
}

fn length(value: usize) -> Result<i32, Error> {
    i32::try_from(value).map_err(|_| Error::Limit)
}
fn check(status: i32) -> Result<(), Error> {
    match status {
        0..=i32::MAX => {
            if status == 0 {
                Ok(())
            } else if status == 66323 {
                Err(Error::Cancelled)
            } else {
                Err(Error::Engine(status))
            }
        }
        _ => Ok(()), // ICU-Warnungen sind negative Werte.
    }
}

unsafe extern "C" fn keep_matching(context: *const c_void, _steps: i32) -> i8 {
    // Der Arc gehört Regex und bleibt bis NACH uregex_close gültig.
    let cancelled = unsafe { &*context.cast::<AtomicBool>() };
    i8::from(!cancelled.load(Ordering::Relaxed))
}

pub(crate) struct Regex {
    handle: NonNull<c_void>,
    text: Vec<u16>,
    cancel: Cancellation,
    groups: i32,
    time_ms: i32,
    stack_bytes: i32,
}
impl Drop for Regex {
    fn drop(&mut self) {
        unsafe {
            fastra_regex_close(self.handle.as_ptr());
        }
    }
}
impl Regex {
    pub fn with_text(&self, text: &str) -> Result<Self, Error> {
        self.cancel.check()?;
        let text: Vec<u16> = text.encode_utf16().collect();
        let count = length(text.len())?;
        let mut status = 0;
        let raw = unsafe { fastra_regex_clone(self.handle.as_ptr(), &mut status) };
        if status > 0 {
            if !raw.is_null() {
                unsafe {
                    fastra_regex_close(raw);
                }
            }
            return Err(Error::Engine(status));
        }
        let result = Self {
            handle: NonNull::new(raw).ok_or(Error::Engine(status))?,
            text,
            cancel: self.cancel.clone(),
            groups: self.groups,
            time_ms: self.time_ms,
            stack_bytes: self.stack_bytes,
        };
        unsafe {
            fastra_regex_text(raw, result.text.as_ptr(), count, &mut status);
            fastra_regex_limits(raw, self.time_ms, self.stack_bytes, &mut status);
            fastra_regex_callback(
                raw,
                keep_matching,
                std::sync::Arc::as_ptr(&result.cancel.0).cast(),
                &mut status,
            );
        }
        check(status)?;
        Ok(result)
    }

    pub fn new(
        pattern: &str,
        text: &str,
        case_sensitive: bool,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        if limits.regex_time_ms <= 0 || limits.regex_stack_bytes <= 0 {
            return Err(Error::Limit);
        }
        let pattern: Vec<u16> = pattern.encode_utf16().collect();
        let text: Vec<u16> = text.encode_utf16().collect();
        let mut status = 0;
        let mut offset = 0;
        let raw = unsafe {
            fastra_regex_open(
                pattern.as_ptr(),
                length(pattern.len())?,
                if case_sensitive { 0 } else { 2 },
                &mut offset,
                &mut status,
            )
        };
        if status > 0 {
            if !raw.is_null() {
                unsafe {
                    fastra_regex_close(raw);
                }
            }
            return Err(Error::Regex {
                code: status,
                offset,
            });
        }
        let mut result = Self {
            handle: NonNull::new(raw).ok_or(Error::Engine(status))?,
            text,
            cancel: cancel.clone(),
            groups: 0,
            time_ms: limits.regex_time_ms,
            stack_bytes: limits.regex_stack_bytes,
        };
        unsafe {
            fastra_regex_limits(
                raw,
                limits.regex_time_ms,
                limits.regex_stack_bytes,
                &mut status,
            );
            fastra_regex_text(
                raw,
                result.text.as_ptr(),
                length(result.text.len())?,
                &mut status,
            );
            fastra_regex_callback(
                raw,
                keep_matching,
                std::sync::Arc::as_ptr(&result.cancel.0).cast(),
                &mut status,
            );
            result.groups = fastra_regex_groups(raw, &mut status);
        }
        check(status)?;
        if result.groups < 0 {
            return Err(Error::Engine(status));
        }
        if result.groups > 10_000 {
            return Err(Error::Limit);
        }
        Ok(result)
    }
    pub fn group_count(&self) -> usize {
        self.groups as usize
    }
    pub fn next(&mut self) -> Result<Option<Vec<Option<Utf16Range>>>, Error> {
        self.cancel.check()?;
        let mut status = 0;
        let found = unsafe { fastra_regex_next(self.handle.as_ptr(), &mut status) };
        check(status)?;
        if found == 0 {
            return Ok(None);
        }
        let mut groups = Vec::with_capacity(self.groups as usize + 1);
        for group in 0..=self.groups {
            let start = unsafe { fastra_regex_start(self.handle.as_ptr(), group, &mut status) };
            let end = unsafe { fastra_regex_end(self.handle.as_ptr(), group, &mut status) };
            check(status)?;
            groups.push(if start < 0 {
                None
            } else {
                if end < start || end as usize > self.text.len() {
                    return Err(Error::InvalidRange);
                }
                Some(Utf16Range {
                    location: start as usize,
                    length: (end - start) as usize,
                })
            });
        }
        self.cancel.check()?;
        Ok(Some(groups))
    }
    pub fn text_units(&self) -> &[u16] {
        &self.text
    }
}

pub(crate) fn casing(text: &str, upper: bool, limit: usize) -> Result<String, Error> {
    casing_with_locale(text, upper, "", limit)
}

pub(crate) fn casing_with_locale(
    text: &str,
    upper: bool,
    locale: &str,
    limit: usize,
) -> Result<String, Error> {
    let locale = std::ffi::CString::new(locale).map_err(|_| Error::InvalidRange)?;
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut status = 0;
    let required = unsafe {
        fastra_case(
            units.as_ptr(),
            length(units.len())?,
            std::ptr::null_mut(),
            0,
            i32::from(upper),
            locale.as_ptr(),
            &mut status,
        )
    };
    if status != 15 {
        check(status)?;
    } // U_BUFFER_OVERFLOW_ERROR ist der Größenabruf.
    let size = usize::try_from(required).map_err(|_| Error::Limit)?;
    if size > limit {
        return Err(Error::Limit);
    }
    let mut output = vec![0u16; size];
    status = 0;
    let written = unsafe {
        fastra_case(
            units.as_ptr(),
            length(units.len())?,
            output.as_mut_ptr(),
            length(size)?,
            i32::from(upper),
            locale.as_ptr(),
            &mut status,
        )
    };
    check(status)?;
    if written < 0 || written as usize > size {
        return Err(Error::InvalidRange);
    }
    let result =
        String::from_utf16(&output[..written as usize]).map_err(|_| Error::InvalidRange)?;
    if result.len() > limit {
        return Err(Error::Limit);
    }
    Ok(result)
}

pub(crate) fn graphemes(text: &str) -> Result<Vec<&str>, Error> {
    let mut result = Vec::new();
    walk_graphemes(text, |grapheme| {
        result.push(grapheme);
        Ok(())
    })?;
    Ok(result)
}
pub(crate) fn walk_graphemes<'a>(
    text: &'a str,
    mut visit: impl FnMut(&'a str) -> Result<(), Error>,
) -> Result<(), Error> {
    struct IteratorHandle(NonNull<c_void>);
    impl Drop for IteratorHandle {
        fn drop(&mut self) {
            unsafe {
                fastra_graphemes_close(self.0.as_ptr());
            }
        }
    }
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut status = 0;
    let raw = unsafe { fastra_graphemes_open(units.as_ptr(), length(units.len())?, &mut status) };
    let handle = NonNull::new(raw).map(IteratorHandle);
    check(status)?;
    let handle = handle.ok_or(Error::Engine(status))?;
    let mut boundaries = text.char_indices();
    let mut unit = 0;
    let mut start = 0;
    loop {
        let end = unsafe { fastra_graphemes_next(handle.0.as_ptr()) };
        if end < 0 {
            break;
        }
        let mut byte_end = start;
        while unit < end as usize {
            let (byte, c) = boundaries.next().ok_or(Error::InvalidRange)?;
            unit += c.len_utf16();
            byte_end = byte + c.len_utf8();
        }
        if unit != end as usize {
            return Err(Error::InvalidRange);
        }
        visit(&text[start..byte_end])?;
        start = byte_end;
    }
    Ok(())
}

pub(crate) fn titlecase(text: &str, locale: &str, limit: usize) -> Result<String, Error> {
    let locale = std::ffi::CString::new(locale).map_err(|_| Error::InvalidRange)?;
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut status = 0;
    let required = unsafe {
        fastra_titlecase(
            units.as_ptr(),
            length(units.len())?,
            std::ptr::null_mut(),
            0,
            locale.as_ptr(),
            &mut status,
        )
    };
    if status != 15 {
        check(status)?;
    }
    let size = usize::try_from(required).map_err(|_| Error::Limit)?;
    if size > limit {
        return Err(Error::Limit);
    }
    let mut output = vec![0u16; size];
    status = 0;
    let written = unsafe {
        fastra_titlecase(
            units.as_ptr(),
            length(units.len())?,
            output.as_mut_ptr(),
            length(size)?,
            locale.as_ptr(),
            &mut status,
        )
    };
    check(status)?;
    let written = usize::try_from(written).map_err(|_| Error::InvalidRange)?;
    if written > size {
        return Err(Error::InvalidRange);
    }
    let result = String::from_utf16(&output[..written]).map_err(|_| Error::InvalidRange)?;
    if result.len() > limit {
        return Err(Error::Limit);
    }
    Ok(result)
}

pub(crate) fn known_locale(locale: &str) -> bool {
    std::ffi::CString::new(locale).is_ok_and(|id| unsafe { fastra_locale_known(id.as_ptr()) != 0 })
}
