use crate::{icu, Error};

#[derive(Debug, PartialEq, Eq)]
pub struct Compiled {
    pub regex_pattern: String,
    pub star_offsets: Vec<usize>,
}

pub fn escape_pattern(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for c in value.chars() {
        if "\\.*+?()[]{}^$|".contains(c) {
            output.push('\\');
        }
        output.push(c);
    }
    output
}
pub fn escape_template(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for c in value.chars() {
        if c == '\\' || c == '$' {
            output.push('\\');
        }
        output.push(c);
    }
    output
}
pub fn compile_find(value: &str) -> Result<Compiled, Error> {
    let graphemes = icu::graphemes(value)?;
    let mut regex_pattern = String::new();
    let mut star_offsets = Vec::new();
    let mut position = 0;
    let mut index = 0;
    while index < graphemes.len() {
        let current = graphemes[index];
        if current == "*" {
            star_offsets.push(position);
            let mut count = 0;
            while index < graphemes.len() && graphemes[index] == "*" {
                index += 1;
                count += 1;
                position += 1;
            }
            regex_pattern.push_str(if count == 1 { "(.+)" } else { "([\\s\\S]+)" });
        } else {
            regex_pattern.push_str(&escape_pattern(current));
            position += current.encode_utf16().count();
            index += 1;
        }
    }
    Ok(Compiled {
        regex_pattern,
        star_offsets,
    })
}

pub fn reference_digits(group_count: usize) -> usize {
    group_count.to_string().len()
}

pub fn reference_spelling(
    number: usize,
    digits: usize,
    group_count: usize,
    next_is_digit: bool,
) -> String {
    let plain = number.to_string();
    let budget = reference_digits(group_count);
    let mut width = digits.max(plain.len());
    if width > budget {
        width = plain.len().max(budget);
    }
    if next_is_digit {
        width = width.max(budget);
    }
    format!("${:0>width$}", plain)
}

pub fn compile_replace(value: &str, capture_count: Option<usize>) -> Result<String, Error> {
    let graphemes = icu::graphemes(value)?;
    let mut output = String::new();
    let mut index = 0;
    let mut positional = 1;
    while index < graphemes.len() {
        if graphemes[index] == "*" {
            while index < graphemes.len() && graphemes[index] == "*" {
                index += 1;
            }
            let next_is_digit = graphemes
                .get(index)
                .and_then(|s| s.chars().next())
                .is_some_and(|c| c.is_ascii_digit());
            output.push_str(
                &capture_count
                    .map(|n| {
                        reference_spelling(
                            positional,
                            positional.to_string().len(),
                            n,
                            next_is_digit,
                        )
                    })
                    .unwrap_or_else(|| format!("${positional}")),
            );
            positional += 1;
            continue;
        }
        if graphemes[index] == "$" {
            if let Some(count) = capture_count {
                let mut end = index + 1;
                let mut digits = String::new();
                while end < graphemes.len()
                    && graphemes[end].len() == 1
                    && graphemes[end].as_bytes()[0].is_ascii_digit()
                {
                    digits.push_str(graphemes[end]);
                    end += 1;
                }
                if let Ok(number) = digits.parse::<usize>() {
                    if number > 0 && number <= count {
                        output.push_str(&format!("${number}"));
                        index = end;
                        continue;
                    }
                }
            }
        }
        output.push_str(&escape_template(graphemes[index]));
        index += 1;
    }
    Ok(output)
}
