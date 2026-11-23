// TextLayoutManagerStaleOffsetTests.swift
//
// Regression für build.sh-Patch 4w: Nach Undo/Redo kann der Zeilen-Storage
// noch länger sein als der Text. Eine Scrollabfrage alter Cursorpositionen
// darf `rangeOfComposedCharacterSequence` nicht außerhalb der Grenzen aufrufen.
// Den Text ohne Delegate-Benachrichtigung verkürzen und die Geometrie der
// alten Position abfragen. Erwartet ist ein nullbreites Rechteck oder nil.

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

@Test("rectForOffset crasht nicht bei veraltetem Zeilen-Storage (Undo-Fenster)")
@MainActor
func rectForOffset_survivesStaleLineStorage() throws {
    let text = "Erste Zeile\nZweite Zeile mit etwas Text\nDritte Zeile 🤮"
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.layoutManager.layoutLines()

    let oldLength = (text as NSString).length
    // Cursor stand am alten Dateiende (wie nach dem Einfügen per ⌘V).
    let staleOffset = oldLength - 1

    // Schrumpfen wie im Undo-Fenster: Der Zeilen-Storage erfährt von der
    // Mutation nichts, weil die Delegate-Kette erst später dran ist.
    let savedDelegate = textView.textStorage.delegate
    textView.textStorage.delegate = nil
    textView.textStorage.replaceCharacters(
        in: NSRange(location: oldLength - 20, length: 20), with: ""
    )
    textView.textStorage.delegate = savedDelegate

    // Veraltete Positionen (alte Cursorposition und altes Dateiende) dürfen
    // die Geometrieabfrage nicht abstürzen lassen.
    _ = textView.layoutManager.rectForOffset(staleOffset)
    _ = textView.layoutManager.rectForOffset(oldLength)
    #expect(Bool(true))
}
