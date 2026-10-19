#!/usr/bin/env python3
"""Theme-Wechsel erhalten Farben anderer Ausschnitte desselben Speichers."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration+Appearance.swift"
old = """            if updateExistingTextAttributes {
                controller.textView.textStorage.setAttributes(
                    controller.attributesFor(nil),
                    range: NSRange(location: 0, length: controller.textView.textStorage.length)
                )
            }"""
new = """            if updateExistingTextAttributes {
                // Ein anderer Ausschnitt teilt die Attribute, besitzt aber
                // eigene gültige Highlight-Bereiche. Nur hier sichtbare
                // Altattribute zurücksetzen; Unsichtbares folgt beim Scrollen.
                let storage = controller.textView.textStorage!
                for range in controller.textView.visibleTextRanges
                    where range.location != NSNotFound && range.location >= 0
                        && range.location < storage.length && range.length > 0 {
                    storage.setAttributes(controller.attributesFor(nil), range: NSRange(
                        location: range.location,
                        length: min(range.length, storage.length - range.location)
                    ))
                }
            }"""
source = path.read_text()
changed = new not in source
if changed:
    if source.count(old) != 1:
        raise SystemExit("Gemeinsamer Theme-Wechsel: Anker fehlt oder ist mehrdeutig")
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source.replace(old, new, 1))
if path.read_text().count(new) != 1:
    raise SystemExit("Gemeinsamer Theme-Wechsel: Selbstprüfung fehlgeschlagen")
print("changed" if changed else "unchanged")
