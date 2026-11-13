#!/usr/bin/env python3
"""Asynchrone Syntaxänderungen melden ihre Ergebnisse ausschließlich auf Main zurück."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "Sources/CodeEditSourceEditor/TreeSitter/TreeSitterClient.swift"
old = """                operation: { completion(.success(operation())) },"""
new = """                operation: {
                    // Fastra: Parsen bleibt im Hintergrund; Highlight-Bereiche
                    // und Textattribute gehören ausschließlich dem Main-Thread.
                    let invalidatedRanges = operation()
                    DispatchQueue.dispatchMainIfNot { completion(.success(invalidatedRanges)) }
                },"""
source = path.read_text()
changed = source.count(old) == 1
if changed:
    if new in source:
        raise SystemExit("TreeSitterClient: alter und neuer Edit-Callback gleichzeitig vorhanden")
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source.replace(old, new, 1))
elif source.count(new) != 1:
    raise SystemExit("TreeSitterClient: Anker für Main-Thread-Edit-Rückmeldung fehlt oder ist mehrdeutig")
verified = path.read_text()
if verified.count(new) != 1 or old in verified:
    raise SystemExit("TreeSitterClient: Selbstprüfung der Main-Thread-Edit-Rückmeldung fehlgeschlagen")
print("changed" if changed else "unchanged")
