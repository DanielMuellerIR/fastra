#!/usr/bin/env python3
"""Großer deterministischer Swift/Rust-Parservergleich ohne eingecheckten Korpus."""
from pathlib import Path
import hashlib
import json
import random
import subprocess
import tempfile
from generate import HERE, REPO, IMAGE, command


def main():
    source = (REPO / 'app/Sources/Fastra/HexEditing.swift').read_text()
    start = source.index('    static func parseRow(')
    parsers = source[start:source.index('    /// Überträgt eine Hex-Vorschau', start)]
    scan = json.loads((HERE / 'whitespace.json').read_text())
    rows = []
    points = set()
    for begin, end in scan['whitespace_suffix_ranges']:
        points.update([begin, end])
    for whitespace in scan['whitespace']:
        for scalar in sorted(points):
            rows.append(('00' + chr(whitespace) + chr(scalar) + 'FF', 2))
    # Kontexte, die bei einer allgemeinen Graphemsegmentierung zusätzliche Regeln haben.
    for begin, end in scan['whitespace_suffix_ranges']:
        for scalar in range(begin, end + 1):
            rows.append(('00 ' + chr(scalar) + '\u200d👩FF', 2))
            rows.append(('00 ' + chr(scalar) + '\u094dकFF', 2))
    randomizer = random.Random(0xFA57)
    atoms = [chr(c) for c in scan['whitespace']] + ['\u0301', '\u034f', '\u200c', '\u200d', '\ufe0f', '\U0001f3fb', '\U000e0020', '\U000e007f', '\u0903', '\u0600', '\u200b', '\ufeff', '\0', '👩', 'क', '\u094d', 'ᄀ', 'ᅡ', '🇩', '+', 'F']
    for _ in range(8192):
        middle = ''.join(randomizer.choice(atoms) for _ in range(randomizer.randrange(9)))
        prefix = ''.join(randomizer.choice(atoms) for _ in range(randomizer.randrange(3)))
        suffix = ''.join(randomizer.choice(atoms) for _ in range(randomizer.randrange(3)))
        rows.append((prefix + '00' + middle + 'FF' + suffix, randomizer.choice([0, 1, 2, 2, 2, 3])))
    for text in ['', '00', '+1', '-0', '+F', 'FF 00', '00\0FF']:
        for expected in range(4):
            rows.append((text, expected))
    native = '''import Foundation\nenum HexEditing {\n''' + parsers + '''\n}
let file=try! String(contentsOfFile:"/work/cases.tsv",encoding:.utf8)
for line in file.split(separator:"\\n",omittingEmptySubsequences:false).dropLast(){
 let fields=line.split(separator:"\\t",omittingEmptySubsequences:false);let encoded=Array(fields[0].utf8)
 var bytes:[UInt8]=[];var index=0
 while index<encoded.count {bytes.append(UInt8(String(decoding:encoded[index..<index+2],as:UTF8.self),radix:16)!);index+=2}
 let text=String(decoding:bytes,as:UTF8.self);let expected=Int(fields[1])!
 if let value=HexEditing.parseRow(text,expectedBytes:expected){print(value.map{String(format:"%02X",$0)}.joined(separator:","))}else{print("ERR")}
}
'''
    rust = r'''#[allow(dead_code)] #[path="/work/model.rs"] mod model;
fn main(){let input=std::fs::read_to_string("/work/cases.tsv").unwrap();for line in input.lines(){let(text,count)=line.split_once('\t').unwrap();let bytes=text.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect::<Vec<_>>();let text=String::from_utf8(bytes).unwrap();match model::parse_row(&text,count.parse().unwrap()){Ok(v)=>println!("{}",v.iter().map(|b|format!("{b:02X}")).collect::<Vec<_>>().join(",")),Err(_)=>println!("ERR")}}}
'''
    model = HERE.parents[1] / 'src/hex_editor/model.rs'
    with tempfile.TemporaryDirectory(prefix='fastra-hex-differential-') as directory:
        work = Path(directory)
        (work / 'cases.tsv').write_text(''.join(text.encode().hex() + '\t' + str(count) + '\n' for text, count in rows))
        (work / 'oracle.swift').write_text(native)
        (work / 'model.rs').write_bytes(model.read_bytes())
        (work / 'driver.rs').write_text(rust)
        base = ['docker', 'run', '--rm', '--pull=never', '--network', 'none', '-v', str(work) + ':/work:ro']
        expected = command(base + [IMAGE, 'bash', '-euc', 'swiftc -O /work/oracle.swift -o /tmp/oracle; /tmp/oracle']).decode().splitlines()
        actual = command(base + ['-e', 'RUSTUP_TOOLCHAIN=1.99.1', 'fastra-linux-package-builder:local', 'bash', '-euc', 'rustc --edition 2021 /work/driver.rs -o /tmp/driver; /tmp/driver']).decode().splitlines()
    assert len(expected) == len(actual) == len(rows)
    for (text, count), swift, rust in zip(rows, expected, actual):
        if swift != rust:
            raise AssertionError((ascii(text), count, swift, rust))
    print(json.dumps({'cases':len(rows),'seed':'0xFA57','swift':'6.2.1','rust':'1.99.1','model_sha256':hashlib.sha256(model.read_bytes()).hexdigest(),'matched':True},indent=2))

if __name__ == '__main__':
    main()
