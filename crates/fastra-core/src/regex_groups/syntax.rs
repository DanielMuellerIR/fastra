use super::*;
use std::ffi::{c_char, c_void, CStr};
#[derive(Debug)]
struct Node {
    kind: String,
    range: Range<usize>,
    named: bool,
    children: Vec<usize>,
}
struct Parse {
    nodes: Vec<Node>,
    cancel: Cancellation,
}
unsafe extern "C" {
    fn fastra_regex_syntax(
        text: *const c_char,
        length: u32,
        emit: unsafe extern "C" fn(*mut c_void, i32, *const c_char, u32, u32, bool) -> bool,
        cancelled: unsafe extern "C" fn(*mut c_void) -> bool,
        context: *mut c_void,
    ) -> i32;
}
unsafe extern "C" fn cancelled(context: *mut c_void) -> bool {
    unsafe { &*context.cast::<Parse>() }.cancel.check().is_err()
}
unsafe extern "C" fn emit(
    context: *mut c_void,
    parent: i32,
    kind: *const c_char,
    start: u32,
    end: u32,
    named: bool,
) -> bool {
    let state = unsafe { &mut *context.cast::<Parse>() };
    let index = state.nodes.len();
    if parent >= 0 {
        let Some(node) = state.nodes.get_mut(parent as usize) else {
            return false;
        };
        node.children.push(index);
    }
    state.nodes.push(Node {
        kind: unsafe { CStr::from_ptr(kind) }
            .to_string_lossy()
            .into_owned(),
        range: start as usize..end as usize,
        named,
        children: vec![],
    });
    true
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Literal,
    Anchor,
    Class,
    Quantifier,
    Delimiter,
    Escape,
    Backreference,
    Alternation,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub kind: Kind,
    pub range: Range<usize>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub number: usize,
    pub name: Option<String>,
    pub range: Range<usize>,
    pub inner: Range<usize>,
}
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Syntax {
    pub tokens: Vec<Token>,
    pub groups: Vec<Group>,
    pub has_errors: bool,
    pub(super) source: String,
    pub(super) unscoped_flags: Vec<Range<usize>>,
}
fn collect(index: usize, nodes: &[Node], source: &str, out: &mut Syntax) {
    let node = &nodes[index];
    let kind = match node.kind.as_str() {
        "pattern_character" => Some(Kind::Literal),
        "start_assertion" | "end_assertion" | "boundary_assertion" | "non_boundary_assertion" => {
            Some(Kind::Anchor)
        }
        "character_class"
        | "character_class_escape"
        | "any_character"
        | "posix_character_class" => Some(Kind::Class),
        "one_or_more" | "zero_or_more" | "optional" | "count_quantifier" => Some(Kind::Quantifier),
        "identity_escape"
        | "control_escape"
        | "control_letter_escape"
        | "unicode_character_escape"
        | "unicode_property_value_expression" => Some(Kind::Escape),
        "decimal_escape" | "backreference_escape" | "named_group_backreference" => {
            Some(Kind::Backreference)
        }
        "|" => Some(Kind::Alternation),
        _ => None,
    };
    if let Some(kind) = kind {
        if let Some(last) = out.tokens.last_mut().filter(|t| {
            kind == Kind::Literal && t.kind == Kind::Literal && t.range.end == node.range.start
        }) {
            last.range.end = node.range.end;
        } else {
            out.tokens.push(Token {
                kind,
                range: node.range.clone(),
            });
        }
        return;
    }
    let capturing = matches!(
        node.kind.as_str(),
        "anonymous_capturing_group" | "named_capturing_group"
    );
    let group = capturing
        || matches!(
            node.kind.as_str(),
            "non_capturing_group" | "lookaround_assertion" | "inline_flags_group"
        );
    if group {
        let children = node.children.iter().map(|&i| &nodes[i]).collect::<Vec<_>>();
        let Some(close) = children.last().filter(|n| n.kind == ")") else {
            out.has_errors = true;
            return;
        };
        let content = children.iter().find(|n| n.kind == "pattern");
        let prefix_end = content.map_or(close.range.start, |n| n.range.start);
        if node.kind == "inline_flags_group" && content.is_none() {
            out.unscoped_flags.push(node.range.clone());
        }
        let number = out.groups.len() + 1;
        if capturing {
            out.groups.push(Group {
                number,
                name: children
                    .iter()
                    .find(|n| n.kind == "group_name")
                    .and_then(|n| source.get(n.range.clone()))
                    .map(str::to_string),
                range: node.range.clone(),
                inner: prefix_end..close.range.start,
            });
        }
        out.tokens.push(Token {
            kind: Kind::Delimiter,
            range: node.range.start..prefix_end,
        });
        for &child in &node.children {
            if nodes[child].kind == "pattern" {
                collect(child, nodes, source, out);
            }
        }
        out.tokens.push(Token {
            kind: Kind::Delimiter,
            range: close.range.clone(),
        });
    } else if node.named {
        for &child in &node.children {
            collect(child, nodes, source, out);
        }
    }
}
pub fn tokenize(source: &str, cancel: &Cancellation) -> Result<Syntax, Error> {
    cancel.check()?;
    if source.len() > 65536 {
        return Err(Error::Limit);
    }
    if source.is_empty() {
        return Ok(Syntax::default());
    }
    let mut state = Parse {
        nodes: vec![],
        cancel: cancel.clone(),
    };
    let status = unsafe {
        fastra_regex_syntax(
            source.as_ptr().cast(),
            source.len() as u32,
            emit,
            cancelled,
            (&mut state as *mut Parse).cast(),
        )
    };
    cancel.check()?;
    if status == 0 {
        return Err(Error::Limit);
    }
    let mut syntax = Syntax {
        has_errors: status == 2,
        source: source.to_string(),
        ..Syntax::default()
    };
    if !syntax.has_errors {
        collect(0, &state.nodes, source, &mut syntax);
    }
    syntax.tokens.sort_by_key(|t| t.range.start);
    syntax.groups.sort_by_key(|g| g.range.start);
    Ok(syntax)
}
