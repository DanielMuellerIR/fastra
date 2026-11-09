use super::*;
use std::ffi::c_void;
include!(concat!(env!("OUT_DIR"), "/folding_catalog.rs"));
unsafe extern "C" {
    fn fastra_folding_ranges(
        grammar: u32,
        python: bool,
        text: *const u8,
        length: u32,
        stop: unsafe extern "C" fn(*mut c_void) -> bool,
        emit: unsafe extern "C" fn(*mut c_void, u32, u32) -> bool,
        context: *mut c_void,
    ) -> i32;
    fn fastra_folding_abi(grammar: u32) -> u32;
}
struct Context<'a, 'b> {
    budget: &'a Budget<'b>,
    ranges: Vec<Range<usize>>,
    error: Option<Failure>,
}
unsafe extern "C" fn stopped(context: *mut c_void) -> bool {
    let context = unsafe { &mut *context.cast::<Context<'_, '_>>() };
    if let Err(error) = context.budget.check() {
        context.error = Some(error);
        true
    } else {
        false
    }
}
unsafe extern "C" fn emit(context: *mut c_void, start: u32, end: u32) -> bool {
    let context = unsafe { &mut *context.cast::<Context<'_, '_>>() };
    if context.ranges.len() >= MAX_RANGES {
        context.error = Some(Failure::Limit);
        false
    } else {
        context.ranges.push(start as usize..end as usize);
        true
    }
}
pub(super) fn ranges(text: &str, language: &str, budget: &Budget<'_>) -> Result<Vec<Range<usize>>> {
    let Some((_, grammar, expected_abi)) = GRAMMARS.iter().find(|(name, _, _)| *name == language)
    else {
        // Der Mac-Katalog enthält bewusst entfernte Grammatik-Provider.
        let catalog: serde_json::Value =
            serde_json::from_str(include_str!("../../native/folding/catalog.json"))
                .map_err(|_| Failure::Unavailable)?;
        return if catalog["languages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l["mac_id"] == language && l["symbol"].is_null())
        {
            Ok(Vec::new())
        } else {
            Err(Failure::Unavailable)
        };
    };
    let abi = unsafe { fastra_folding_abi(*grammar) };
    if abi != *expected_abi {
        return Err(Failure::Unavailable);
    }
    let mut context = Context {
        budget,
        ranges: Vec::new(),
        error: None,
    };
    let status = unsafe {
        fastra_folding_ranges(
            *grammar,
            language == "python",
            text.as_ptr(),
            text.len() as u32,
            stopped,
            emit,
            (&mut context as *mut Context<'_, '_>).cast(),
        )
    };
    if let Some(error) = context.error {
        return Err(error);
    }
    match status {
        0 => Ok(context.ranges),
        3 => Err(Failure::Limit),
        _ => Err(Failure::Unavailable),
    }
}
#[cfg(test)]
pub(super) fn abis() -> Vec<(&'static str, u32)> {
    GRAMMARS
        .iter()
        .map(|(name, id, _)| (*name, unsafe { fastra_folding_abi(*id) }))
        .collect()
}
