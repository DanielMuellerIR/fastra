#!/usr/bin/env python3
"""Auswahl beim Einrücken und Return mit CR/CRLF korrigieren."""
from pathlib import Path
import sys
editor = Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor/Controller/TextViewController+IndentLines.swift'
newline = Path(sys.argv[2]) / 'Sources/TextFormation/NewlineProcessingFilter.swift'
pending = {}
s = editor.read_text()
if '    public func handleIndent(inwards: Bool = false) {' not in s:
    raise SystemExit('IndentLines: Funktionsanker fehlt')
if 'kurze Einrückungen dürfen weder negative Cursor' not in s and '        var selectionIndex = 0' not in s:
    raise SystemExit('IndentLines: unbekannter Ausgangsstand')
start = s.index('    public func handleIndent(')
end = s.index('    /// This method is used to handle tabs', start)
replacement = Path(__file__).with_name('indent-selection.swift').read_text().rstrip() + '\n\n'
s = s[:start] + replacement + s[end:]
start = s.find('    private func adjustIndentation(')
if start >= 0:
    end = s.index('    func countLeadingSpacesUpTo(', start)
    s = s[:start] + s[end:]
assert replacement in s and 'private func updateSelection(' not in s
pending[editor] = s
s = newline.read_text()
old = '        recognizer.processMutation(mutation)'
new = '''        // Fastra: Return verwendet das Zeilenende des Dokuments.
        if ["\\n", "\\r", "\\r\\n"].contains(mutation.string) {
            recognizer.resetState()
            return filterHandler(mutation, in: interface, with: providers)
        }
        recognizer.processMutation(mutation)'''
if new not in s:
    if s.count(old) != 1: raise SystemExit('NewlineProcessingFilter: Anker fehlt')
    s = s.replace(old, new)
assert s.count(new) == 1
pending[newline] = s
ranges = Path(sys.argv[2]) / 'Sources/TextFormation/TextStoring+Extensions.swift'
s = ranges.read_text()
old = '        while startLoc > 0 {\n            let preceedingStart'
new = '        while startLoc > 0 {\n            // CRLF ist ein Umbruch; seine LF-Hälfte ist keine leere Vorzeile.\n            if substring(from: NSRange(location: startLoc, length: 1)) == "\\n",\n               substring(from: NSRange(location: startLoc - 1, length: 1)) == "\\r" {\n                startLoc -= 1\n            }\n            let preceedingStart'
if new not in s:
    if s.count(old) != 1: raise SystemExit('TextStoring: CRLF-Anker fehlt')
    s = s.replace(old, new)
assert s.count(new) == 1
pending[ranges] = s
changed = False
for path, source in pending.items():
    if path.read_text() != source:
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(source); changed = True
print('changed' if changed else 'unchanged')
