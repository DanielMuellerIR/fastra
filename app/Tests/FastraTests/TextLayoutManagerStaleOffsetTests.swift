// TextLayoutManagerStaleOffsetTests.swift
//
// Regressionstest für den build.sh-Patch 4w: Während Undo/Redo schrumpft der
// Text, der Zeilen-Storage des Layout-Managers hinkt einen Moment hinterher.
// Fragt ein zwischengeschobener Scroll in diesem Fenster `rectForOffset` mit
// einer veralteten Cursorposition (hinter dem neuen Textende), warf
// `rangeOfComposedCharacterSequence(at:)` eine NSRangeException und riss die
// App ab (Daniel-Befund 2026-07-24: Crash nach ⌘V + ⌘Z).
//
// Der Test stellt GENAU dieses Fenster nach: Der Storage schrumpft OHNE die
// Delegate-Benachrichtigung (wie im Rennen zwischen Undo-Mutation und
// Zeilen-Storage-Update), danach wird die Geometrie der alten Cursorposition
// abgefragt. Ohne Patch stürzt der Testprozess mit NSRangeException ab; mit
// Patch kommt ein ehrliches 0-breites Rechteck (oder nil) zurück.

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
