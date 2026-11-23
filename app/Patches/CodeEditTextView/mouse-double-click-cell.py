import sys

path = sys.argv[1]
src = open(path).read()
pristine = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectWord(nil)
    }'''
# Vorgaengerfassung dieses Patches (rueckte um genau eine UTF-16-Einheit
# zurueck — bei Emoji/kombinierenden Zeichen mitten in den Cluster).
previous = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle.
        // `textOffsetAtPoint` rundet als Einfuege-Position auf; ein Klick auf
        // die rechte Haelfte des letzten Wortzeichens landet dadurch auf dem
        // Folgezeichen und wuerde dessen Leerraum markieren. Liegt der
        // Klickpunkt tatsaechlich in der Zelle des Vorgaengerzeichens, wird
        // die Auswahlbasis dorthin verschoben (NSTextView-Verhalten).
        let clickPoint = convert(event.locationInWindow, from: nil)
        if let caretOffset = layoutManager.textOffsetAtPoint(clickPoint),
           caretOffset > 0,
           let previousRect = layoutManager.rectForOffset(caretOffset - 1),
           previousRect.contains(clickPoint) {
            selectionManager.setSelectedRange(
                NSRange(location: caretOffset - 1, length: 0)
            )
        }
        selectWord(nil)
    }'''
new = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt).
        // `textOffsetAtPoint` rundet als Einfuege-Position auf; ein Klick auf
        // die rechte Haelfte des letzten Wortzeichens landet dadurch auf dem
        // Folgezeichen und wuerde dessen Leerraum markieren. Das
        // Vorgaengerzeichen kann aus mehreren UTF-16-Einheiten bestehen
        // (Emoji, kombinierende Akzente) — die Auswahlbasis rueckt deshalb an
        // den Anfang seiner zusammengesetzten Sequenz, nie mitten hinein
        let clickPoint = convert(event.locationInWindow, from: nil)
        if let caretOffset = layoutManager.textOffsetAtPoint(clickPoint),
           caretOffset > 0 {
            let previousStart = (string as NSString)
                .rangeOfComposedCharacterSequence(at: caretOffset - 1).location
            if let previousRect = layoutManager.rectForOffset(previousStart),
               previousRect.contains(clickPoint) {
                selectionManager.setSelectedRange(
                    NSRange(location: previousStart, length: 0)
                )
            }
        }
        selectWord(nil)
    }'''
interim_head = """        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle —
        // zusammengesetzte Sequenz."""
if pristine in src:
    src = src.replace(pristine, new, 1)
elif previous in src:
    src = src.replace(previous, new, 1)
elif interim_head in src:
    # Zwischenstand mit umbrochenem Marker: nur den Kommentarkopf auf die
    # einzeilige, grep-bare Form heben — der Code selbst ist bereits richtig.
    src = src.replace(interim_head,
        """        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt).
        // Hinweis: siehe Patch 4u in build.sh.""", 1)
else:
    raise SystemExit(
        f"{path}: handleDoubleClick hat sich geaendert — Patch 4u pruefen"
    )
open(path, "w").write(src)
