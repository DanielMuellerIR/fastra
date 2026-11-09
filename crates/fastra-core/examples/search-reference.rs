use fastra_core::{preview, Cancellation, Limits, SearchMode, SearchRequest, Utf16Range};
use serde_json::{json, Value};
use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    io::stdin()
        .take(4 * 1024 * 1024)
        .read_to_string(&mut input)
        .unwrap();
    let cases: Vec<Value> = serde_json::from_str(&input).unwrap();
    let mut output = Vec::new();
    for case in cases {
        let text = case["text"].as_str().unwrap();
        let request = SearchRequest {
            pattern: case["pattern"].as_str().unwrap().into(),
            replacement: case["template"].as_str().unwrap().into(),
            mode: if case["wildcard"].as_bool() == Some(true) {
                SearchMode::Wildcard
            } else {
                SearchMode::Regex
            },
            case_sensitive: case["flags"].as_u64().unwrap_or(0) != 2,
            range: case["range"].as_array().map(|r| Utf16Range {
                location: r[0].as_u64().unwrap() as usize,
                length: r[1].as_u64().unwrap() as usize,
            }),
        };
        let cancel = Cancellation::default();
        match preview(text, 0, 0, &request, Limits::default(), &cancel) {
            Ok(p) => {
                let ranges: Vec<_> = p
                    .matches()
                    .iter()
                    .map(|m| {
                        m.captures
                            .iter()
                            .map(|r| {
                                r.map(|r| json!([r.location, r.length]))
                                    .unwrap_or(json!([-1, 0]))
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect();
                output.push(json!({"id":case["id"], "ranges":ranges, "output": p.apply(text, 0, 0, &(0..p.matches().len()).collect::<Vec<_>>(), &cancel).unwrap()}));
            }
            Err(fastra_core::Error::Regex { .. }) => {
                output.push(json!({"id":case["id"], "error":"compile"}))
            }
            Err(error) => panic!("{}: {error}", case["id"]),
        }
    }
    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}
