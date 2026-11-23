// ColumnTypingDriftTests.swift
//
// Bei Rechteckersetzungen müssen nachfolgende Cursor um
// `replacementLength - range.length` verschoben werden. Nur die Ersatzlänge
// zu addieren summiert je Zeile Fehler auf; weiteres Tippen würde an falschen
// Positionen einfügen. Öffentliche Eingabe-APIs für Rechteckauswahl, Backspace
// und Tippen prüfen das Verhalten unabhängig von der Patch-Zeile.

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

@MainActor
private func makeTextView(_ text: String) -> CodeEditTextView.TextView {
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    textView.layoutManager.layoutLines()
    return textView
}

@MainActor
private func cursorLocations(_ textView: CodeEditTextView.TextView) -> [Int] {
    textView.selectionManager.textSelections
        .map(\.range.location)
        .sorted()
}

@Test("Tippen in eine Mehrfachauswahl setzt jeden Cursor hinter seine eigene Ersetzung")
@MainActor
func typingIntoMultipleRangesPlacesCursorsAfterEachReplacement() {
    // Drei Zeilen mit unterschiedlich langem führendem Leerraum:
    // Tab, vier Leerzeichen, zwei Leerzeichen.
    let textView = makeTextView("\t500\n    600\n  700")

    // Die Rechteckauswahl markiert pro Zeile den führenden Leerraum.
    textView.selectionManager.setSelectedRanges([
        NSRange(location: 0, length: 1),
        NSRange(location: 5, length: 4),
        NSRange(location: 13, length: 2),
    ])

    // Ein getipptes Zeichen ersetzt jeden Bereich.
    textView.insertText(" ")

    #expect(textView.string == " 500\n 600\n 700")
    // Jeder Cursor muss direkt hinter seinem eingefügten Leerzeichen stehen.
    // Mit dem Delta-Fehler standen sie bei [1, 7, 16] — mitten im Text bzw.
    // hinter dem Dokumentende.
    #expect(cursorLocations(textView) == [1, 6, 11])

    // Der zweite Tastendruck ist der sichtbare Schaden: Er fügt an den
    // verrutschten Positionen ein und reißt die Zeilen auseinander.
    textView.insertText(" ")
    #expect(textView.string == "  500\n  600\n  700")
    #expect(cursorLocations(textView) == [2, 8, 14])
}

@Test("Rechteckauswahl, Backspace und wiederholtes Tippen rücken alle Zeilen gleichmäßig ein")
@MainActor
func columnBackspaceThenTypingKeepsLinesAligned() {
    // Gemischter Leerraum: Tab, vier Leerzeichen, zwei Leerzeichen plus Tab.
    // Alle enden visuell an Spalte 4.
    let textView = makeTextView(
        "\t500 g Pasta\n    600 g Haehnchen\n  \t700 ml Bruehe"
    )

    // Rechteck aufziehen: Auswahl über den Leerraum der ersten Zeile,
    // dann zweimal spaltenweise nach unten erweitern.
    textView.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1)])
    #expect(textView.fastraSelectColumn(upwards: false))
    #expect(textView.fastraSelectColumn(upwards: false))

    let snapshot = textView.fastraColumnSelectionSnapshot
    #expect(snapshot?.ranges == [
        NSRange(location: 0, length: 1),
        NSRange(location: 13, length: 4),
        NSRange(location: 33, length: 3),
    ])

    // Backspace löscht den markierten Leerraum aller Zeilen.
    textView.deleteBackward(nil)
    #expect(textView.string == "500 g Pasta\n600 g Haehnchen\n700 ml Bruehe")
    #expect(cursorLocations(textView) == [0, 12, 28])

    // Wiederholtes Tippen: Alle Zeilen müssen gleichmäßig nach rechts
    // wandern, die Cursor bleiben an derselben visuellen Spalte.
    textView.insertText(" ")
    textView.insertText(" ")
    textView.insertText(" ")
    #expect(textView.string
            == "   500 g Pasta\n   600 g Haehnchen\n   700 ml Bruehe")
    #expect(cursorLocations(textView) == [3, 18, 37])
}
