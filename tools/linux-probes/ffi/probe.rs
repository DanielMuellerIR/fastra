use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    slice,
};
#[repr(C)]
pub struct ResultBytes {
    data: *mut u8,
    length: usize,
    status: i32,
}
// Eine Kopie mit eindeutigem Rust-Besitz; der Host gibt ausschließlich über free zurück.
#[no_mangle]
pub unsafe extern "C" fn fastra_probe_copy(
    data: *const u8,
    length: usize,
    mode: i32,
) -> ResultBytes {
    let empty = |status| ResultBytes {
        data: std::ptr::null_mut(),
        length: 0,
        status,
    };
    if length > 1024 * 1024 || (data.is_null() && length > 0) {
        return empty(1);
    }
    if mode == 1 {
        return empty(2);
    }
    match catch_unwind(AssertUnwindSafe(|| {
        if mode == 2 {
            panic!("probe panic");
        }
        let input = if length == 0 {
            &[]
        } else {
            slice::from_raw_parts(data, length)
        };
        if std::str::from_utf8(input).is_err() {
            return empty(3);
        }
        let owned = input.to_vec().into_boxed_slice();
        let len = owned.len();
        ResultBytes {
            data: Box::into_raw(owned) as *mut u8,
            length: len,
            status: 0,
        }
    })) {
        Ok(r) => r,
        Err(_) => empty(4),
    }
}
#[no_mangle]
pub unsafe extern "C" fn fastra_probe_free(data: *mut u8, length: usize) {
    if !data.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            data, length,
        )));
    }
}
