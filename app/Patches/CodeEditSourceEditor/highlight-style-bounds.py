#!/usr/bin/env python3
"""Verhindert Attributschreibvorgänge außerhalb des aktuellen Textspeichers."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor/Highlighting/Highlighter.swift'
old = '''    func styleContainerDidUpdate(in range: NSRange) {
        guard let textView, let attributeProvider else { return }
        textView.textStorage.beginEditing()

        let storage = textView.textStorage

        var offset = range.location
        for run in styleContainer.runsIn(range: range) {
            guard let range = NSRange(location: offset, length: run.length).intersection(range) else {
                continue
            }
            storage?.setAttributes(attributeProvider.attributesFor(run.value?.capture), range: range)
            offset += range.length
        }

        textView.textStorage.endEditing()
    }'''
new = '''    func styleContainerDidUpdate(in range: NSRange) {
        // Fastra: eine verspätete Farbantwort darf nur den aktuellen Speicher färben.
        guard let textView, let attributeProvider, let storage = textView.textStorage,
              range.location >= 0, range.location < storage.length, range.length > 0 else { return }
        let currentRange = NSRange(location: range.location,
                                   length: min(range.length, storage.length - range.location))
        storage.beginEditing()
        defer { storage.endEditing() }
        var offset = currentRange.location
        for run in styleContainer.runsIn(range: currentRange) {
            let attributes = attributeProvider.attributesFor(run.value?.capture)
            // Auch ein Theme-Provider kann AppKit reentrant zur Bearbeitung bringen.
            guard textView.textStorage === storage, offset < storage.length else { break }
            let length = min(run.length, storage.length - offset)
            if length > 0 { storage.setAttributes(attributes, range: NSRange(location: offset, length: length)) }
            offset += run.length
        }
    }'''
source = path.read_text()
changed = source.count(old) == 1
if changed:
    source = source.replace(old, new, 1)
elif source.count(new) != 1:
    raise SystemExit('Highlighter.swift: Anker für Patch 4z26 fehlt oder ist mehrdeutig')
if source.count(new) != 1:
    raise SystemExit('Highlighter.swift: Patch 4z26 ist unvollständig')
if changed:
    path.write_text(source)
if path.read_text().count(new) != 1:
    raise SystemExit('Highlighter.swift: Selbstprüfung von Patch 4z26 fehlgeschlagen')
print('changed' if changed else 'clean')
