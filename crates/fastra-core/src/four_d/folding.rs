use super::{lexical, tokens, Mask};
use crate::{
    folding::{Failure, MAX_RANGES},
    Cancellation,
};
use std::ops::Range;
struct Block {
    close: &'static str,
    start: usize,
    branch: Option<usize>,
}
fn newline_before(text: &str, end: usize) -> usize {
    if text[..end].ends_with("\r\n") {
        2
    } else if text[..end].ends_with(['\r', '\n']) {
        1
    } else {
        0
    }
}
fn push(ranges: &mut Vec<Range<usize>>, start: usize, end: usize) -> Result<(), Failure> {
    if end > start {
        if ranges.len() >= MAX_RANGES {
            return Err(Failure::Limit);
        }
        ranges.push(start..end);
    }
    Ok(())
}
pub(crate) fn ranges(text: &str, cancel: &Cancellation) -> Result<Vec<Range<usize>>, Failure> {
    let mask = lexical::mask(text, lexical::StringPolicy::UntilLf, cancel).map_err(|error| {
        if matches!(error, super::Error::Cancelled) {
            Failure::Cancelled
        } else {
            Failure::Limit
        }
    })?;
    let mut ranges = Vec::new();
    let mut blocks: Vec<Block> = Vec::new();
    let mut function = None;
    let mut position = 0;
    while position < text.len() {
        cancel.check()?;
        let end = text[position..]
            .char_indices()
            .find(|(_, c)| matches!(c, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}'))
            .map_or(text.len(), |(i, _)| position + i);
        let line_end = if end == text.len() {
            end
        } else {
            end + if text[end..].starts_with("\r\n") {
                2
            } else {
                text[end..].chars().next().unwrap().len_utf8()
            }
        };
        let first = text[position..end]
            .char_indices()
            .find(|(_, c)| !tokens::folding_space(*c))
            .map_or(end, |(i, _)| position + i);
        let keyword = if first < end && mask[first] == Mask::Code {
            tokens::folding_keyword(&text[first..end], cancel)?
        } else {
            String::new()
        };
        if blocks.last().is_some_and(|b| b.close == "end sql") && keyword != "end sql" {
            position = line_end;
            continue;
        }
        let closing = match keyword.as_str() {
            "if" => Some("end if"),
            "case of" => Some("end case"),
            "for" => Some("end for"),
            "for each" => Some("end for each"),
            "while" => Some("end while"),
            "repeat" => Some("until"),
            "use" => Some("end use"),
            "try" => Some("end try"),
            "begin sql" => Some("end sql"),
            _ => None,
        };
        if matches!(keyword.as_str(), "function" | "class constructor") {
            if let Some(start) = function {
                push(
                    &mut ranges,
                    start,
                    position - newline_before(text, position),
                )?;
            }
            function = Some(end);
            blocks.clear();
        } else if let Some(close) = closing {
            if blocks.len() >= 512 {
                return Err(Failure::Limit);
            }
            blocks.push(Block {
                close,
                start: end,
                branch: None,
            });
        } else if matches!(
            keyword.as_str(),
            "end if"
                | "end case"
                | "end for"
                | "end for each"
                | "end while"
                | "until"
                | "end use"
                | "end try"
                | "end sql"
        ) {
            if blocks.last().is_some_and(|b| b.close == keyword) {
                let block = blocks.pop().unwrap();
                if let Some(branch) = block.branch {
                    push(&mut ranges, branch, first)?;
                }
                push(&mut ranges, block.start, first)?;
            } else {
                blocks.clear();
            }
        } else if let Some(block) = blocks.last_mut() {
            let branch = (keyword == "else" && matches!(block.close, "end if" | "end case"))
                || (keyword == "catch" && block.close == "end try")
                || (first < end
                    && text.as_bytes()[first] == b':'
                    && mask[first] == Mask::Code
                    && block.close == "end case");
            if branch {
                if let Some(start) = block.branch {
                    push(&mut ranges, start, first)?;
                }
                block.branch = Some(end);
            }
        }
        position = line_end;
    }
    if let Some(start) = function {
        push(
            &mut ranges,
            start,
            text.len() - newline_before(text, text.len()),
        )?;
    }
    cancel.check()?;
    Ok(ranges)
}
