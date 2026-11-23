import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let insertedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        removeLayoutLinesIn(range: insertedStringRange)
        insertNewLines(for: editedRange)

        attachments.textUpdated(atOffset: editedRange.location, delta: delta)

        invalidateLayoutForRange(insertedStringRange)'''
new = '''        let replacedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        removeLayoutLinesIn(range: replacedStringRange)
        insertNewLines(for: editedRange)

        attachments.textUpdated(atOffset: editedRange.location, delta: delta)

        // Fastra-Patch: neuen Editierbereich invalidieren. Der zuvor ersetzte
        // Bereich ist bei reinen Einfuegungen leer und kann nach dem Umbau der
        // Zeilenstruktur auf die falschen alten Fragmente zeigen.
        invalidateLayoutForRange(editedRange)'''
if old not in src:
    raise SystemExit(
        f"{path}: Editierbereichs-Invalidierung hat sich geaendert — Patch 4s pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
