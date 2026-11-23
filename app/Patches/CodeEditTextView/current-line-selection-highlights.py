import sys

path = sys.argv[1]
src = open(path).read()
old_loop = '''        var highlightedLines: Set<TextLine.ID> = []
        // For each selection in the rect
        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                drawHighlightedLine(
                    in: rect,
                    for: textSelection,
                    context: context,
                    highlightedLines: &highlightedLines
                )
            } else {
                drawSelectedRange(in: rect, for: textSelection, context: context)
            }
        }'''
new_loop = '''        var highlightedLines: Set<TextLine.ID> = []
        // Fastra-Patch: aktuelle Zeile bleibt auch bei Textauswahl sichtbar.
        // Mehrfach-Cursor markieren weiterhin alle Cursorzeilen; sobald echte
        // Selektionen existieren, markiert nur deren primaere/letzte Range
        // genau eine aktive Zeile (wichtig fuer Rechteckauswahl).
        for offset in fastraHighlightedLineOffsets {
            drawHighlightedLine(
                in: rect,
                at: offset,
                context: context,
                highlightedLines: &highlightedLines
            )
        }
        for textSelection in textSelections where !textSelection.range.isEmpty {
            drawSelectedRange(in: rect, for: textSelection, context: context)
        }'''
old_signature = '''    private func drawHighlightedLine(
        in rect: NSRect,
        for textSelection: TextSelection,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(textSelection.range.location),'''
new_signature = '''    private func drawHighlightedLine(
        in rect: NSRect,
        at offset: Int,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(offset),'''
if old_loop not in src or old_signature not in src:
    raise SystemExit(
        f"{path}: Auswahl-Zeichenstruktur hat sich geaendert — Patch 4y pruefen"
    )
src = src.replace(old_loop, new_loop, 1).replace(old_signature, new_signature, 1)

anchor = '''extension TextSelectionManager {
    /// Draws line backgrounds and selection rects for each selection in the given rect.'''
replacement = '''extension TextSelectionManager {
    /// Offsets der Zeilen, die als aktuelle Zeile gezeichnet werden. Leere
    /// Mehrfach-Cursor behalten je eine Zeile. Bei echter Auswahl gibt es
    /// genau eine aktive Zeile; sonst ist die letzte Range die primaere.
    /// `pivot` bezeichnet den festen Anker, daher ist das jeweils andere
    /// Range-Ende die aktive Kante.
    public var fastraHighlightedLineOffsets: [Int] {
        let selections = textSelections.filter { !$0.range.isEmpty }
        guard let primary = selections.last else {
            return textSelections.map { $0.range.location }
        }
        // Eine Rechteckauswahl kennt ihre aktive Kopfzeile selbst. Ihre
        // Zeilenbereiche entstehen immer von oben nach unten, bei einem nach
        // oben gezogenen Rechteck ist die Kopfzeile also die erste Range.
        // Ohne diese Nachfrage leuchtete dort die unterste Zeile.
        if let head = textView?.fastraColumnSelectionHeadOffset {
            return [head]
        }
        guard let pivot = primary.pivot else {
            return [primary.range.location]
        }
        return [pivot == primary.range.location ? primary.range.max : primary.range.location]
    }

    /// Draws line backgrounds and selection rects for each selection in the given rect.'''
if anchor not in src:
    raise SystemExit(f"{path}: Extension-Anker fehlt — Patch 4y pruefen")
src = src.replace(anchor, replacement, 1)
open(path, "w").write(src)
