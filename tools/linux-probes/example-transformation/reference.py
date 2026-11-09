#!/usr/bin/env python3
"""Erzeugt den Swift-Bestandslauf; Ausgabe anschließend mit Swift ausführen."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("repo", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source = (args.repo / "app/Sources/Fastra/Patterns/PatternLibrary.swift").read_text()
marker = "enum ExampleTransformation {"
if source.count(marker) != 1:
    raise SystemExit("Original ExampleTransformation nicht eindeutig gefunden")
original = marker + source.split(marker, 1)[1]
vectors = json.loads((args.repo / "crates/fastra-core/tests/fixtures/example-transformation-swift.json").read_text())
pairs = [[v["source"], v["destination"]] for v in vectors]
# JSON-Escapes dieser Eingaben sind zugleich gültige Swift-Stringliterale.
main = "\nlet pairs: [[String]] = " + json.dumps(pairs, ensure_ascii=False) + r'''
let output: [[String: Any]] = pairs.map { pair in
    let value = ExampleTransformation.infer(source: pair[0], destination: pair[1])
    return ["source": pair[0], "destination": pair[1], "find": value?.findPattern as Any? ?? NSNull(), "replace": value?.replacePattern as Any? ?? NSNull()]
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''
args.output.write_text("import Foundation\n" + original + main)
