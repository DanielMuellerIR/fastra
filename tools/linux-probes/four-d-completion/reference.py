#!/usr/bin/env python3
"""Erzeugt ausführbare Oracles aus dem unveränderten Swift-Bestand, keine Ersatzlogik."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("repo", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--kind", choices=["prefixes", "matches", "symbols"], default="prefixes")
parser.add_argument("--catalog-json", type=Path)
args = parser.parse_args()
if args.catalog_json:
    data = json.loads(args.catalog_json.read_text())
    lines = ["# Kanonische FourDSymbols-Fakten aus Original-Swift; Attribution THIRD-PARTY-NOTICES.md."]
    for kind, field in [("C", "commands"), ("K", "constants")]:
        for name in data[field]:
            detail = (data["details"].get(name.lower()) or "") if kind == "C" else ""
            if any(c in name + detail for c in "\t\r\n"):
                raise SystemExit("Unerwartete TSV-Trennzeichen in Originalfakten")
            lines.append("\t".join([kind, name, detail] if detail else [kind, name]))
    args.output.write_text("\n".join(lines) + "\n")
    raise SystemExit(0)
source = args.repo / "app/Sources/Fastra"
symbols = (source / "FourDSymbols.swift").read_text()
if args.kind == "symbols":
    main = r'''
let value: [String: Any] = ["commands": FourDSymbols.commands, "constants": FourDSymbols.constants, "details": FourDSymbols.commandDetails.mapValues { $0.signature as Any? ?? NSNull() }]
let data = try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
'''
    args.output.write_text(symbols + main)
    raise SystemExit(0)
original = (source / "FourDCompletion.swift").read_text()
logic = original[original.index("enum FourDCompletionLogic {"):original.index("/// Ein Eintrag der Vorschlagsliste")]
foundation = (source / "FourDSignatureHelp.swift").read_text() + "\n" + (source / "FourDTokenizer.swift").read_text()
if args.kind == "prefixes":
    cases = json.loads((args.repo / "crates/fastra-core/tests/fixtures/four-d-completion-prefix-swift.json").read_text())
    texts = list(dict.fromkeys(case["text"] for case in cases))
    main = "\nlet texts: [String] = " + json.dumps(texts, ensure_ascii=False) + r'''
var output: [[String: Any]] = []
for text in texts {
    for cursor in 0...text.utf16.count {
        let range = FourDCompletionLogic.prefixRange(in:text,utf16CursorLocation:cursor)
        output.append(["text":text,"cursor":cursor,"range":range.map { [$0.location,$0.length] } as Any? ?? NSNull(),"inside":FourDSignatureHelpLogic.isInsideCommentOrString(in:text,utf16Location:cursor)])
    }
}
'''
else:
    cases = json.loads((args.repo / "crates/fastra-core/tests/fixtures/four-d-completion-matches-swift.json").read_text())
    main = "\nlet prefixes: [String] = " + json.dumps([case["prefix"] for case in cases], ensure_ascii=False) + r'''
let projects = ["ALProject","SAME","ZZProject","éMethod","İProject","ΣProject"]
let components = [FourDCompletionLogic.ComponentMethodEntry(name:"ALProject",componentName:"Shadowed"),.init(name:"ComponentOnly",componentName:"C"),.init(name:"e\u{301}Method",componentName:"D"),.init(name:"İComponent",componentName:"I")]
let output: [[String: Any]] = prefixes.map { prefix in
    ["prefix":prefix,"items":FourDCompletionLogic.matches(forPrefix:prefix,projectMethods:projects,componentMethods:components).map { item in ["name":item.name,"signature":item.signature as Any? ?? NSNull(),"project":item.isProjectMethod,"constant":item.isConstant,"component":item.componentName as Any? ?? NSNull()] }]
}
'''
main += r'''
let data = try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
'''
args.output.write_text("import Foundation\n" + symbols + "\n" + foundation + "\n" + logic + main)
