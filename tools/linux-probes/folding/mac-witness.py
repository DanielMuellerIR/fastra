#!/usr/bin/env python3
"""Referenzbereiche aus dem unveränderten Swift-Provider, ohne App-/Fensterstart."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--products', type=Path, required=True, help='Existing verified Mac build products')
parser.add_argument('--output', type=Path, required=True, help='New output file; never overwrites')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
products = args.products.resolve()
output = args.output.resolve()
if output.exists():
    raise SystemExit('Output must not exist')
fixtures = repo / 'crates/fastra-core/tests/fixtures/mac-folding-regions.json'
provider = repo / 'app/Sources/Fastra/CodeFolding.swift'
source = provider.read_text()
source = source[source.index('enum FoldingRanges'):source.index('@MainActor\nenum CodeFoldingCommands')]
with tempfile.TemporaryDirectory(prefix='fastra-fold-witness-') as temporary:
    work = Path(temporary)
    (work / 'Provider.swift').write_text('import Foundation\nimport CodeEditLanguages\nimport SwiftTreeSitter\nstruct SourceFoldRegion {let range:NSRange;let depth:Int}\n' + source)
    (work / 'TreeSitter.modulemap').write_text('module TreeSitter { header "' + str(repo / 'app/.build/checkouts/tree-sitter/lib/include/tree_sitter/api.h') + '" export * }\n')
    shutil.copytree(products / 'CodeEditLanguages_CodeEditLanguages.bundle', work / 'CodeEditLanguages_CodeEditLanguages.bundle')
    shutil.copyfile(repo / 'tools/linux-probes/folding/provider-witness.swift', work / 'main.swift')
    command = ['swiftc', '-I', str(products), '-F', str(products), '-Xcc', '-fmodule-map-file=' + str(work / 'TreeSitter.modulemap'), str(work / 'Provider.swift')]
    command += [str(repo / 'app/Sources/Fastra' / name) for name in ('FourDTokenizer.swift', 'FourDSymbols.swift')]
    command += [str(work / 'main.swift')]
    command += [str(products / name) for name in ('SwiftTreeSitter.o', 'TreeSitter.o', 'CodeEditLanguages.o')]
    command += ['-framework', 'CodeLanguages_Container', '-o', str(work / 'witness')]
    subprocess.run(command, check=True)
    result = subprocess.run([str(work / 'witness'), str(fixtures)], check=True, capture_output=True)
    decoded = json.loads(result.stdout)
    if len(decoded) != len(json.loads(fixtures.read_text())):
        raise SystemExit('Incomplete witness output')
    with output.open('xb') as stream:
        stream.write(result.stdout)
print('Mac provider vectors:', len(decoded), 'SHA256:', hashlib.sha256(result.stdout).hexdigest())
