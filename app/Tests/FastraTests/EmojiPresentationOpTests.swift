// EmojiPresentationOpTests.swift
//
// Text-Transformation „Emoji-Darstellung erzwingen/aufheben": Zeichen wie ⏸
// sind laut Unicode Textzeichen und erscheinen erst mit dem Variantenselektor
// U+FE0F überall als farbiges Emoji (Daniel-Befund 2026-07-27, Sprechskript
// mit 61 nackten U+23F8). Geprüft wird, WAS die Operation anfasst — und
// besonders, was sie in Ruhe lässt.

import Foundation
import Testing
@testable import Fastra

private func scalars(_ text: String) -> [UInt32] {
    text.unicodeScalars.map(\.value)
}

/// Wendet die Operation auf den ganzen Text an (leere Selektion).
private func added(_ text: String) -> String? {
    TextOperations.addEmojiPresentation(
        in: text, selection: NSRange(location: 0, length: 0)
    )?.newText
}

private func removed(_ text: String) -> String? {
    TextOperations.removeEmojiPresentation(
        in: text, selection: NSRange(location: 0, length: 0)
    )?.newText
}

@Test("Nacktes ⏸ bekommt den Variantenselektor")
func addsVariationSelectorToBareSymbol() throws {
    let result = try #require(added("Pause \u{23F8} weiter"))
    #expect(scalars(result) == scalars("Pause \u{23F8}\u{FE0F} weiter"))
}

@Test("Genau Daniels Skriptzeile: mehrere Pausenzeichen in Folge")
func addsSelectorToRepeatedSymbols() throws {
    // `⏸⏸` steht im Skript für die längere Pause — beide Zeichen zählen.
    let result = try #require(added("- `\u{23F8}\u{23F8}` deutlich absetzen"))
    #expect(scalars(result)
        == scalars("- `\u{23F8}\u{FE0F}\u{23F8}\u{FE0F}` deutlich absetzen"))
}

@Test("Zweimal anwenden ändert nichts mehr")
func operationIsIdempotent() throws {
    let once = try #require(added("Stop \u{23F9} Ende"))
    // Kein zweiter Selektor, und die Operation meldet ehrlich „nichts zu tun".
    #expect(added(once) == nil)
}

@Test("Emoji mit eigener Farbdarstellung bleibt unangetastet")
func leavesRealEmojiAlone() {
    // 🎶 und ✅ haben Emoji_Presentation — ein U+FE0F wäre überflüssig.
    #expect(added("Ton 🎶 und ✅ fertig") == nil)
}

@Test("Schriftzeichen und ASCII bleiben unangetastet")
func leavesTextualCharactersAlone() {
    // ©, ® und ™ sind formal Emoji-fähig, praktisch immer Text.
    #expect(added("© 2026 Firma ® Marke ™") == nil)
    // #, * und Ziffern sind Keycap-Basen — ein Selektor würde Text in Symbole
    // verwandeln.
    #expect(added("# Titel 1 * 2 * 3") == nil)
    // Interpunktion bleibt Interpunktion.
    #expect(added("Achtung\u{203C} wirklich\u{2049}") == nil)
    // Und Daniels Foliensymbole: einfache Pfeile, Stern, Haken, Bullet.
    #expect(added("\u{2192} \u{2193} \u{2726} \u{2713} \u{2022} \u{2014}") == nil)
}

@Test("Ausdrückliche Textform U+FE0E bleibt erhalten")
func keepsExplicitTextPresentation() {
    #expect(added("Pause \u{23F8}\u{FE0E} weiter") == nil)
}

@Test("Aufheben entfernt nur die selbst ergänzten Selektoren")
func removeUndoesOnlyOwnSelectors() throws {
    let full = "Pause \u{23F8}\u{FE0F} und \u{00A9}\u{FE0F} bleibt"
    let result = try #require(removed(full))
    // Das ⏸ verliert den Selektor, das © behält ihn: Fastra hätte ihn dort
    // nie ergänzt und nimmt deshalb auch nichts weg.
    #expect(scalars(result) == scalars("Pause \u{23F8} und \u{00A9}\u{FE0F} bleibt"))
    // U+FE0E bleibt ebenfalls stehen.
    #expect(removed("Pause \u{23F8}\u{FE0E}") == nil)
}

@Test("Hin und zurück ergibt den Ausgangstext")
func roundTripRestoresOriginal() throws {
    let original = "Pause `\u{23F8}` und `\u{23F8}\u{23F8}` sowie 🎶 und ©"
    let withSelectors = try #require(added(original))
    let back = try #require(removed(withSelectors))
    #expect(scalars(back) == scalars(original))
}

@Test("Nur die Selektion wird verändert")
func respectsSelection() throws {
    let text = "erst \u{23F8} dann \u{23F8}"
    // Selektion umfasst nur das erste Symbol (Offset 5, Länge 1).
    let result = try #require(TextOperations.addEmojiPresentation(
        in: text, selection: NSRange(location: 5, length: 1)
    )?.newText)
    #expect(scalars(result) == scalars("erst \u{23F8}\u{FE0F} dann \u{23F8}"))
}

@Test("Zeichenmenge beider Richtungen ist identisch")
func selectorRuleMatchesBothDirections() {
    // Positivfälle aus der gemessenen Liste …
    for value: UInt32 in [0x23F8, 0x23F9, 0x23FA, 0x25B6, 0x2764, 0x26A0, 0x2B05] {
        #expect(TextOperations.needsEmojiVariationSelector(Unicode.Scalar(value)!))
    }
    // … und die bewusst ausgenommenen Zeichen.
    for value: UInt32 in [0x00A9, 0x00AE, 0x2122, 0x203C, 0x2049,
                          0x0023, 0x002A, 0x0030, 0x2192, 0x1F3B6] {
        #expect(!TextOperations.needsEmojiVariationSelector(Unicode.Scalar(value)!))
    }
}

@Test("Auswahlgrenze zwischen Basiszeichen und Selektor erzeugt keinen Doppel-Selektor")
@MainActor
func selectionBoundaryInsideClusterStaysIdempotent() throws {
    // "⏸️" = U+23F8 U+FE0F. Die Auswahl endet GENAU zwischen beiden —
    // vorher sah die Transformation nur das Basiszeichen und hängte einen
    // ZWEITEN Selektor an (Review 2026-08-02). Die Range wird jetzt auf
    // zusammengesetzte Sequenzen ausgeweitet; der vorhandene Selektor wird
    // erkannt und nichts verändert.
    let text = "vor \u{23F8}\u{FE0F} nach"
    let result = TextOperations.addEmojiPresentation(
        in: text, selection: NSRange(location: 0, length: 5)
    )
    #expect(result == nil)
    // Auswahl, die ein Surrogatpaar halbiert, zerschneidet keine Zeichen:
    // Das 🎶 (2 UTF-16-Einheiten) bleibt intakt, der Rest der Auswahl wird
    // normal behandelt.
    let music = "\u{23F8} 🎶"
    let half = try #require(TextOperations.addEmojiPresentation(
        in: music, selection: NSRange(location: 0, length: 3)
    ))
    #expect(half.newText == "\u{23F8}\u{FE0F} 🎶")
}
