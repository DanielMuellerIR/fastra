import sys

path = sys.argv[1]
src = open(path).read()
old = '''        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  visibleRange.intersection(line.range) != nil || selection.range.location == textView.length,
                  !highlightedLines.contains(line.data.id) else {'''
new = '''        // Fastra-Patch: Gutter folgt derselben aktiven Auswahlzeile
        // wie die Textflaeche; Rechteck-/Mehrzeilenauswahl faerbt nie jede
        // betroffene Zeile als aktuelle Zeile ein.
        for offset in selectionManager.fastraHighlightedLineOffsets {
            guard let line = textView.layoutManager.textLineForOffset(offset),
                  visibleRange.intersection(line.range) != nil || offset == textView.length,
                  !highlightedLines.contains(line.data.id) else {'''
if old not in src:
    raise SystemExit(
        f"{path}: Gutter-Auswahlstruktur hat sich geaendert — Patch 4y pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
