// TextLinePrepareForDisplayClampTests.swift
//
// Regression für build.sh-Patches 4z/4z1: Ein reentranter Scroll kann während
// Undo Zeilenlayout mit veraltetem, längerem lineStorage anstoßen.
// `prepareForDisplay` muss die Range gegen den aktuellen Text begrenzen;
// `layoutLines` darf inkonsistente Zwischenstände nicht auslegen. Ohne Schutz
// würde `attributedSubstring(from:)` eine NSRangeException auslösen.

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

/// TextView mit veraltetem Zeilen-Storage: Der Text schrumpft ohne die
/// Delegate-Benachrichtigung — wie im Rennen zwischen Undo-Mutation und
/// Zeilen-Storage-Update (Muster aus TextLayoutManagerStaleOffsetTests).
@MainActor
private func makeTextViewWithStaleLineStorage() -> TextView {
    let text = "Erste Zeile\nZweite Zeile mit deutlich mehr Text als nötig\n"
        + "Dritte Zeile, damit mehrere Zeilen im Storage stehen"
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.layoutManager.layoutLines()

    let oldLength = (text as NSString).length
    let savedDelegate = textView.textStorage.delegate
    textView.textStorage.delegate = nil
    textView.textStorage.replaceCharacters(
        in: NSRange(location: oldLength - 60, length: 60), with: ""
    )
    textView.textStorage.delegate = savedDelegate
    return textView
}

@Test("prepareForDisplay crasht nicht bei Range hinter dem Textende (Undo-Fenster)")
@MainActor
func prepareForDisplay_survivesStaleRange() throws {
    // Der TextLine-Initialisierer ist paketintern — die Instanzen kommen
    // deshalb aus dem echten lineStorage einer TextView. Deren Ranges
    // beschreiben nach dem stillen Schrumpfen den alten, längeren Text.
    let textView = makeTextViewWithStaleLineStorage()
    let displayData = TextLine.DisplayData(
        maxWidth: 400,
        lineHeightMultiplier: 1,
        estimatedLineHeight: 14
    )
    let storageLength = textView.textStorage.length

    // Fall 1: Zeile ganz hinter dem aktuellen Textende (die letzte Zeile des
    // alten Textes) — der 4z-Patch kehrt ohne Typeset zurück.
    let lastLine = try #require(textView.layoutManager.textLineForIndex(2))
    #expect(lastLine.range.location >= storageLength,
            "Aufbaufehler: letzte alte Zeile nicht hinter dem Textende")
    lastLine.data.prepareForDisplay(
        displayData: displayData,
        range: lastLine.range,
        stringRef: textView.textStorage,
        markedRanges: nil,
        attachments: []
    )

    // Fall 2: Zeile ragt nur teilweise über das Textende hinaus — der
    // 4z-Patch klemmt auf den echten Rest und typesettet diesen.
    let partialLine = try #require(textView.layoutManager.textLineForIndex(1))
    #expect(partialLine.range.location < storageLength,
            "Aufbaufehler: mittlere Zeile nicht teilweise gültig")
    #expect(partialLine.range.location + partialLine.range.length > storageLength,
            "Aufbaufehler: mittlere Zeile ragt nicht über das Ende hinaus")
    partialLine.data.prepareForDisplay(
        displayData: displayData,
        range: partialLine.range,
        stringRef: textView.textStorage,
        markedRanges: nil,
        attachments: []
    )

    // Kein inhaltliches Expect nötig: Der Test beweist, dass die Aufrufe den
    // Prozess nicht mehr abreißen (ohne Patch käme er nie bis hierher).
    #expect(Bool(true))
}

@Test("layoutLines layoutet nicht gegen einen veralteten Zeilen-Storage")
@MainActor
func layoutLines_skipsInconsistentLineStorage() throws {
    // Der 4z1-Patch ersetzt den toten Transaktionsschutz: Weicht die Länge
    // des Zeilen-Storage vom Text ab, steigt layoutLines früh aus, statt mit
    // veralteten Ranges in prepareForDisplay zu laufen. Ohne beide Patches
    // bräche dieser Aufruf mit der NSRangeException ab.
    let textView = makeTextViewWithStaleLineStorage()
    textView.layoutManager.layoutLines()
    #expect(Bool(true))
}
