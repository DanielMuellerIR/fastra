#!/usr/bin/env python3
"""Dekorative Klammermarkierung folgt Cursor und Viewport auch bei Sprüngen."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor/Controller/TextViewController+EmphasizeBracket.swift'
source = path.read_text()
helper = '''    // Fastra-Patch: Cursorspruenge verbinden keinen alten Viewport mit EOF.
    // Im sichtbaren Bereich bleiben die bisherigen Suchgrenzen unveraendert.
    internal static func fastraEmphasisLimit(from: Int, viewport: NSRange, limit: Int, reverse: Bool) -> Int {
        let span = viewport.length + 4096
        return reverse ? min(from, max(limit, from - span)) : max(from, min(limit, from + span))
    }

'''
edits = [
    ('    /// # Dev Note', helper + '    /// # Dev Note'),
    ('''    private func emphasizeForwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        if let characterIndex''', '''    private func emphasizeForwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        let viewport = textView.visibleTextRange ?? .zero
        if let characterIndex'''),
    ('''            limit: min((textView.visibleTextRange ?? .zero).max + 4096, textView.documentRange.max),''',
     '''            limit: Self.fastraEmphasisLimit(from: range.location, viewport: viewport,
                limit: min(viewport.max + 4096, textView.documentRange.max), reverse: false),'''),
    ('''    private func emphasizeBackwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        if let characterIndex''', '''    private func emphasizeBackwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        let viewport = textView.visibleTextRange ?? .zero
        if let characterIndex'''),
    ('''            limit: max((textView.visibleTextRange?.location ?? 0) - 4096, textView.documentRange.location),''',
     '''            limit: Self.fastraEmphasisLimit(from: range.location - 1, viewport: viewport,
                limit: max(viewport.location - 4096, textView.documentRange.location), reverse: true),''')
]
original = source
for old, new in edits:
    if new not in source:
        if source.count(old) != 1:
            raise SystemExit('Klammermarkierung: Anker fehlt oder ist mehrdeutig')
        source = source.replace(old, new, 1)
    if source.count(new) != 1:
        raise SystemExit('Klammermarkierung: Selbstprüfung fehlgeschlagen')
if source != original:
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source)
if path.read_text() != source:
    raise SystemExit('Klammermarkierung: geschriebene Quelle stimmt nicht')
print('changed' if source != original else 'unchanged')
