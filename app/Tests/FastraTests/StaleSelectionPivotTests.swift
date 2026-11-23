// StaleSelectionPivotTests.swift
//
// Ein Edit muss den festen Anker einer Shift-Auswahl (`TextSelection.pivot`)
// aktualisieren. Nach Backspace könnte er sonst rechts vom Cursor bleiben;
// Shift+→ erzeugt dann über den Schrumpf-Zweig eine negative Auswahl-Länge,
// die beim nächsten Tippen den Undo-Manager abbrechen lässt.
// Öffentliche Bewegungs- und Einfüge-APIs prüfen das reale Verhalten.

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

@MainActor
private func makeTextView(_ text: String) -> CodeEditTextView.TextView {
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    textView.layoutManager.layoutLines()
    return textView
}

@Test("Shift-Auswahl nach Backspace erzeugt keine negative Länge")
@MainActor
func shiftSelectAfterBackspaceKeepsRangeValid() {
    let textView = makeTextView("0123456789ABCDEF")

    // 1. Cursor hinter Zeichen 9, dann Shift+← und Shift+→: Auswahl wird
    //    auf- und wieder abgebaut, der Anker (pivot = 10) bleibt gesetzt.
    textView.selectionManager.setSelectedRange(NSRange(location: 10, length: 0))
    textView.selectionManager.moveSelections(
        direction: .backward, destination: .character, modifySelection: true)
    textView.selectionManager.moveSelections(
        direction: .forward, destination: .character, modifySelection: true)

    // 2. Backspace: löscht Zeichen 9, der Cursor steht auf 9 — der alte
    //    Anker zeigt jetzt hinter den Cursor.
    textView.deleteBackward(nil)
    #expect(textView.selectionManager.textSelections.first?.range
            == NSRange(location: 9, length: 0))

    // 3. Shift+→: soll das Zeichen rechts vom Cursor markieren. Mit dem
    //    veralteten Anker entstand hier {10, -1}.
    textView.selectionManager.moveSelections(
        direction: .forward, destination: .character, modifySelection: true)

    let selection = textView.selectionManager.textSelections.first?.range
        ?? NSRange(location: NSNotFound, length: 0)
    #expect(selection.length >= 0,
            "Auswahl mit negativer Länge: \(selection)")
    #expect(selection == NSRange(location: 9, length: 1))

    // 4. Tippen ersetzt die Auswahl — auf dem unkorrigierten Stand brach
    //    die App genau hier mit SIGTRAP im Undo-Manager ab. Der Backspace
    //    hat die „9" entfernt, das markierte „A" wird durch „X" ersetzt.
    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string == "012345678XBCDEF")
}

@Test("Tippen nach Shift-Auswahl und erneutem Tippen bleibt stabil")
@MainActor
func typingAfterCollapsedShiftSelectionStaysStable() {
    // Zweiter Weg zum selben veralteten Anker: Auswahl per Shift+←
    // ersetzen (Tippen), weitertippen, dann Backspace und Shift+→.
    let textView = makeTextView("Zeit: 0800-1200")

    textView.selectionManager.setSelectedRange(NSRange(location: 10, length: 0))
    textView.selectionManager.moveSelections(
        direction: .backward, destination: .character, modifySelection: true)
    // Auswahl {9, 1} überschreiben, dann zwei Zeichen anhängen.
    textView.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
    textView.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
    // Backspace zieht den Cursor vor den stehengebliebenen Anker zurück.
    textView.deleteBackward(nil)
    textView.deleteBackward(nil)
    textView.selectionManager.moveSelections(
        direction: .forward, destination: .character, modifySelection: true)

    let selection = textView.selectionManager.textSelections.first?.range
        ?? NSRange(location: NSNotFound, length: 0)
    #expect(selection.length >= 0,
            "Auswahl mit negativer Länge: \(selection)")

    // Der Tastendruck darf nie abstürzen, egal wie die Auswahl aussieht.
    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.string.contains("X"))
}

@Test("setSelectedRange weist negative Längen ab")
@MainActor
func setSelectedRangeRejectsNegativeLength() {
    let textView = makeTextView("0123456789")
    textView.selectionManager.setSelectedRange(NSRange(location: 3, length: 0))
    // Ein korrupter Bereich mit negativer Länge darf die Auswahl nicht
    // erreichen; die bestehende Auswahl bleibt stehen.
    textView.selectionManager.setSelectedRange(NSRange(location: 5, length: -2))
    #expect(textView.selectionManager.textSelections.first?.range
            == NSRange(location: 3, length: 0))
    textView.selectionManager.setSelectedRanges([NSRange(location: 5, length: -2)])
    #expect(textView.selectionManager.textSelections.isEmpty
            || textView.selectionManager.textSelections.allSatisfy { $0.range.length >= 0 })
}

@Test("replaceCharacters überlebt einen korrupten Auswahlbereich")
@MainActor
func replaceCharactersSurvivesCorruptRange() {
    // Sicherheitsgrenze unabhängig von der Anker-Korrektur: Selbst wenn
    // irgendein Pfad wieder einen Bereich mit negativer Länge liefert,
    // darf der Tastendruck weder abstürzen noch Text verfälschen.
    let textView = makeTextView("0123456789")
    textView.replaceCharacters(
        in: [NSRange(location: 6, length: -2)], with: "X")
    #expect(textView.string == "0123456789")
}
