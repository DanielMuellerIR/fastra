use serde_json::{json, Value};
use std::{
    ffi::c_void,
    io::{self, Read},
};
#[link(name = "fastra_icu_probe")]
extern "C" {
    fn probe_open(p: *const u16, n: i32, flags: u32, s: *mut i32) -> *mut c_void;
    fn probe_text(r: *mut c_void, p: *const u16, n: i32, s: *mut i32);
    fn probe_next(r: *mut c_void, s: *mut i32) -> i32;
    fn probe_groups(r: *mut c_void, s: *mut i32) -> i32;
    fn probe_start(r: *mut c_void, g: i32, s: *mut i32) -> i32;
    fn probe_end(r: *mut c_void, g: i32, s: *mut i32) -> i32;
    fn probe_replace(
        r: *mut c_void,
        p: *const u16,
        n: i32,
        out: *mut u16,
        cap: i32,
        s: *mut i32,
    ) -> i32;
    fn probe_limit(r: *mut c_void, s: *mut i32);
    fn probe_close(r: *mut c_void);
    fn probe_region(r: *mut c_void, a: i32, b: i32, s: *mut i32);
    fn probe_cancel(r: *mut c_void, s: *mut i32);
    fn probe_case(p: *const u16, n: i32, out: *mut u16, cap: i32, upper: i32, s: *mut i32) -> i32;
    fn probe_first_grapheme(p: *const u16, n: i32, s: *mut i32) -> i32;
}
fn casing(value: &str, upper: bool) -> String {
    let input: Vec<u16> = value.encode_utf16().collect();
    let mut out = vec![0u16; input.len() * 3 + 16];
    let mut status = 0;
    let n = unsafe {
        probe_case(
            input.as_ptr(),
            input.len() as i32,
            out.as_mut_ptr(),
            out.len() as i32,
            upper as i32,
            &mut status,
        )
    };
    assert!(status <= 0);
    String::from_utf16(&out[..n as usize]).unwrap()
}
fn expand(segment: &str, text: &[u16], groups: &Value) -> String {
    let mut output = String::new();
    let mut chars = segment.chars().peekable();
    let digits = (groups.as_array().unwrap().len() - 1).to_string().len();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                output.push(next);
            }
            continue;
        }
        if c == '$' && chars.peek().map(|c| c.is_ascii_digit()).unwrap_or(false) {
            let mut number = String::new();
            while number.len() < digits && chars.peek().map(|c| c.is_ascii_digit()).unwrap_or(false)
            {
                number.push(chars.next().unwrap());
            }
            let g = number.parse::<usize>().unwrap();
            if let Some(r) = groups.as_array().unwrap().get(g) {
                let a = r[0].as_i64().unwrap();
                let n = r[1].as_u64().unwrap() as usize;
                if a >= 0 {
                    output
                        .push_str(&String::from_utf16(&text[a as usize..a as usize + n]).unwrap());
                }
            }
        } else {
            output.push(c);
        }
    }
    output
}
fn case_replacement(template: &str, text: &[u16], groups: &Value) -> String {
    let mut pieces = vec![];
    let mut segment = String::new();
    let mut chars = template.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                if "ULulE".contains(next) {
                    pieces.push((std::mem::take(&mut segment), None));
                    pieces.push((String::new(), Some(next)));
                } else {
                    segment.push(c);
                    segment.push(next);
                }
            } else {
                segment.push(c);
            }
        } else {
            segment.push(c);
        }
    }
    pieces.push((segment, None));
    let mut mode = None;
    let mut shot = None;
    let mut out = String::new();
    for (segment, op) in pieces {
        if let Some(op) = op {
            match op {
                'U' => {
                    mode = Some(true);
                    shot = None
                }
                'L' => {
                    mode = Some(false);
                    shot = None
                }
                'u' => shot = Some(true),
                'l' => shot = Some(false),
                'E' => {
                    mode = None;
                    shot = None
                }
                _ => unreachable!(),
            };
            continue;
        }
        let expanded = expand(&segment, text, groups);
        if expanded.is_empty() {
            continue;
        }
        let units: Vec<u16> = expanded.encode_utf16().collect();
        let mut start = 0;
        if let Some(upper) = shot.take() {
            let mut status = 0;
            start = unsafe { probe_first_grapheme(units.as_ptr(), units.len() as i32, &mut status) }
                as usize;
            assert!(status <= 0);
            out.push_str(&casing(
                &String::from_utf16(&units[..start]).unwrap(),
                upper,
            ));
        }
        let rest = String::from_utf16(&units[start..]).unwrap();
        out.push_str(&mode.map(|upper| casing(&rest, upper)).unwrap_or(rest));
    }
    out
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Value = serde_json::from_str(&input).unwrap();
    let mut results = vec![];
    for c in cases.as_array().unwrap() {
        let p: Vec<u16> = c["regex"].as_str().unwrap().encode_utf16().collect();
        let text: Vec<u16> = c["text"].as_str().unwrap().encode_utf16().collect();
        let template: Vec<u16> = c["template"].as_str().unwrap().encode_utf16().collect();
        let mut s = 0;
        let mut ranges = vec![];
        unsafe {
            let r = probe_open(
                p.as_ptr(),
                p.len() as i32,
                c["flags"].as_u64().unwrap() as u32,
                &mut s,
            );
            if s > 0 {
                results.push(json!({"id":c["id"],"error":s}));
                continue;
            }
            probe_limit(r, &mut s);
            probe_text(r, text.as_ptr(), text.len() as i32, &mut s);
            if let Some(region) = c["range"].as_array() {
                let a = region[0].as_i64().unwrap() as i32;
                probe_region(r, a, a + region[1].as_i64().unwrap() as i32, &mut s);
            }
            if c["cancelled"].as_bool() == Some(true) {
                probe_cancel(r, &mut s);
            }
            let count = probe_groups(r, &mut s);
            while probe_next(r, &mut s) != 0 && s <= 0 {
                let mut groups = vec![];
                for g in 0..=count {
                    let a = probe_start(r, g, &mut s);
                    let b = probe_end(r, g, &mut s);
                    groups.push(json!([a, if a < 0 { 0 } else { b - a }]));
                }
                ranges.push(json!(groups));
                assert!(ranges.len() < 10000);
            }
            if s > 0 {
                results.push(json!({"id":c["id"],"error":s}));
                probe_close(r);
                continue;
            }
            if c["caseTemplate"].as_bool() == Some(true) || c["range"].is_array() {
                let mut output = String::new();
                let mut cursor = 0;
                for groups in &ranges {
                    let start = groups[0][0].as_u64().unwrap() as usize;
                    let length = groups[0][1].as_u64().unwrap() as usize;
                    output.push_str(&String::from_utf16(&text[cursor..start]).unwrap());
                    let replacement = if c["caseTemplate"].as_bool() == Some(true) {
                        case_replacement(c["template"].as_str().unwrap(), &text, groups)
                    } else {
                        expand(c["template"].as_str().unwrap(), &text, groups)
                    };
                    output.push_str(&replacement);
                    cursor = start + length;
                }
                output.push_str(&String::from_utf16(&text[cursor..]).unwrap());
                results.push(json!({"id":c["id"],"ranges":ranges,"output":output}));
                probe_close(r);
                continue;
            }
            let mut output = vec![0u16; 65536];
            let n = probe_replace(
                r,
                template.as_ptr(),
                template.len() as i32,
                output.as_mut_ptr(),
                output.len() as i32,
                &mut s,
            );
            if s > 0 {
                results.push(json!({"id":c["id"],"error":s}));
            } else {
                results.push(json!({"id":c["id"],"ranges":ranges,"output":String::from_utf16(&output[..n as usize]).unwrap()}));
            }
            probe_close(r);
        }
    }
    println!("{}", serde_json::to_string_pretty(&results).unwrap());
}
