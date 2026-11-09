#!/usr/bin/env python3
"""Erzeugt Referenzen aus den unveränderten reinen Swift-Originaltypen."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
IMAGE = "swift:6.2.1-noble"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def command(args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def rust_string(text):
    result = '"'
    for char in text:
        if char in ('"', '\\'):
            result += '\\' + char
        elif 0x20 <= ord(char) <= 0x7e:
            result += char
        else:
            result += '\\u{' + format(ord(char), 'x') + '}'
    return result + '"'

def numbers(values):
    return '&[' + ','.join(map(str, values)) + ']'

def state(value):
    changes = '&[' + ','.join('Change{offset:%d,old:%d,new:%d}' % (c['offset'], c['old'], c['new']) for c in value['changes']) + ']'
    rows = '&[' + ','.join(rust_string(r) for r in value['rows']) + ']'
    return ('ReferenceState{revision:%d,dirty:%s,can_undo:%s,can_redo:%s,changes:%s,output:%s,rows:%s,page_offset:%d,page:%s}' %
            (value['revision'], str(value['dirty']).lower(), str(value['canUndo']).lower(), str(value['canRedo']).lower(), changes, numbers(value['output']), rows, value['pageOffset'], numbers(value['page'])))

def compact(value, depth=0):
    # Kleine numerische Bytefelder bleiben lesbar auf einer Zeile.
    if not isinstance(value, (dict, list)) or isinstance(value, list) and all(isinstance(v, (int, bool)) for v in value):
        return json.dumps(value, ensure_ascii=True, separators=(',', ':'))
    pad = '  ' * depth
    if isinstance(value, list):
        return '[\n' + ',\n'.join(pad + '  ' + compact(v, depth + 1) for v in value) + '\n' + pad + ']'
    return '{\n' + ',\n'.join(pad + '  ' + json.dumps(k) + ': ' + compact(v, depth + 1) for k, v in sorted(value.items())) + '\n' + pad + '}'

def main():
    source_path = REPO / 'app/Sources/Fastra/HexEditing.swift'
    source_bytes = source_path.read_bytes()
    source = source_bytes.decode('utf-8')
    types = source[source.index('struct HexByteChange:'):source.index('enum HexEditing {')]
    parse_start = source.index('    static func parseRow(')
    parsers = source[parse_start:source.index('    /// Überträgt eine Hex-Vorschau', parse_start)]
    session = source[source.index('struct HexEditSession:'):]
    combined = 'import Foundation\nenum L10n { static func string(_ value:String)->String { value } }\n' + types + '\nenum HexEditing {\n' + parsers + '\n}\n' + session + '\n' + (HERE / 'runner.swift').read_text()
    image_id = command(['docker', 'image', 'inspect', IMAGE, '--format', '{{.Id}}']).decode().strip()
    with tempfile.TemporaryDirectory(prefix='fastra-hex-reference-') as directory:
        work = Path(directory)
        (work / 'reference.swift').write_text(combined)
        (work / 'scan.swift').write_text((HERE / 'whitespace-scan.swift').read_text())
        arguments = ['docker', 'run', '--rm', '--pull=never', '--network', 'none', '-v', str(work) + ':/work:ro', IMAGE, 'bash', '-euc']
        reference = json.loads(command(arguments + ['swiftc -O /work/reference.swift -o /tmp/reference; /tmp/reference']))
        scan = json.loads(command(arguments + ['swiftc -O /work/scan.swift -o /tmp/scan; /tmp/scan']))
    reference['metadata'] = {'swift':'6.2.1','image':IMAGE,'image_id':image_id,'original_source':'app/Sources/Fastra/HexEditing.swift','source_sha256':digest(source_bytes)}
    (HERE / 'reference.json').write_text(compact(reference) + '\n')
    (HERE / 'whitespace.json').write_text(compact(scan) + '\n')
    lines = ['// Generierte tatsächliche Swift-6.2.1-Referenzwerte; generate.py erneuert diese Datei.', '#[rustfmt::skip]', 'const PARSE_CASES: &[ParseCase] = &[']
    for case in reference['parse']:
        values = 'None' if case['values'] is None else 'Some(' + numbers(case['values']) + ')'
        lines.append('    ParseCase{text:%s,expected:%d,values:%s},' % (rust_string(case['text']), case['expected'], values))
    lines += ['];', '#[rustfmt::skip]', 'const SESSION_CASES: &[ReferenceScenario] = &[']
    for scenario in reference['sessions']:
        lines.append('    ReferenceScenario{name:%s,source:%s,initial:%s,steps:&[' % (rust_string(scenario['name']), numbers(scenario['source']), state(scenario['initial'])))
        for step in scenario['steps']:
            action = step['action']
            encoded = 'ReferenceAction::Edit{offset:%d,text:%s}' % (action['offset'], rust_string(action['text'])) if action['kind'] == 'edit' else 'ReferenceAction::' + action['kind'].title()
            lines.append('        ReferenceStep{action:%s,changed:%s,invalid:%s,state:%s},' % (encoded, str(step['changed']).lower(), str(step['invalid']).lower(), state(step['state'])))
        lines.append('    ]},')
    lines += ['];', '#[rustfmt::skip]', 'const EXPECTED_WHITESPACE_SUFFIX: &[(u32,u32)] = &[']
    for start, end in scan['whitespace_suffix_ranges']:
        lines.append('    (0x%X,0x%X),' % (start, end))
    lines += ['];']
    (HERE / 'reference.rs').write_text('\n'.join(lines) + '\n')
    print('PASS Swift originals: %d parser cases, %d sessions, %d Unicode scalars' % (len(reference['parse']), len(reference['sessions']), scan['scalar_count']))

if __name__ == '__main__':
    main()
