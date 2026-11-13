#!/usr/bin/env python3
"""Auch eine einzelne programmatische Auswahl zeichnet die Textfläche neu."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager.swift"
source = path.read_text()
old = """        textSelections = [selection]
        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))"""
new = """        textSelections = [selection]
        updateSelectionViews()
        // Auswahlflächen werden von der TextView gezeichnet, nicht vom Cursor.
        delegate?.setNeedsDisplay()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))"""
changed = new not in source
if changed:
    if source.count(old) != 1:
        raise SystemExit("Auswahl-Neuzeichnen: eindeutiger Anker fehlt")
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source.replace(old, new, 1))
if path.read_text().count(new) != 1:
    raise SystemExit("Auswahl-Neuzeichnen: Selbstprüfung fehlgeschlagen")
print("changed" if changed else "unchanged")
