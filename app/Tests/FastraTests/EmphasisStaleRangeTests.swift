// EmphasisStaleRangeTests.swift
//
// Regressionstests für den Absturz vom 2026-08-28 (Crash-Report
// EFD87C70-8440-4AA9-9D92-24E87E27B802): SIGTRAP in
// `EmphasisManager.updateLayerBackgrounds` → `TextLayoutManager.rectsFor`
// während des Zeichnens.
//
// Wurzel: Die Treffer-Markierungen der Suche speichern ihre Bereiche
// statisch. Schrumpft das Dokument danach (Rechteck-Backspace über alle
// Zeilen), zeigt ein gespeicherter Bereich hinter das Dokumentende. Beim
// nächsten Zeichnen lief `rectsFor(range:)` mit dem UNGEKAPPTEN Bereich in
// `rangeOfComposedCharacterSequence` — NSRangeException, AppKit bricht die
// App in `_crashOnException` ab. `roundedPathForRange` berechnete zwar einen
// gekappten Bereich (`validRange`), reichte dann aber das Original weiter.
//
// Geprüft wird der echte Zeichenpfad mit veralteten Bereichen; ohne den
// Clamp-Patch stürzt der Testprozess mit derselben Exception ab.

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

@Test("rectsFor und roundedPathForRange kappen Bereiche hinter dem Dokumentende")
@MainActor
func layoutRectsClampStaleRanges() {
    let textView = makeTextView("0123456789")

    // Bereich ragt über das Dokumentende hinaus (Rest eines geschrumpften
    // Dokuments) — ohne Clamp: NSRangeException beim Composed-Character-
    // Lookup an Offset 54.
    let overhang = textView.layoutManager.rectsFor(
        range: NSRange(location: 5, length: 50)
    )
    #expect(!overhang.isEmpty)

    // Bereich liegt VOLLSTÄNDIG hinter dem Dokumentende: kein Rechteck.
    let beyond = textView.layoutManager.rectsFor(
        range: NSRange(location: 20, length: 5)
    )
    #expect(beyond.isEmpty)

    // Der Pfad-Weg des EmphasisManagers über denselben Bereich.
    let path = textView.layoutManager.roundedPathForRange(
        NSRange(location: 5, length: 50)
    )
    #expect(path != nil)
}

@Test("Veraltete Emphasis-Bereiche überleben ein geschrumpftes Dokument ohne Absturz")
@MainActor
func staleEmphasisSurvivesShrunkenDocument() {
    let textView = makeTextView("0123456789")
    let manager = textView.emphasisManager

    // Treffer-Markierung wie die Live-Suche sie setzt — zum Zeitpunkt des
    // Setzens vollständig gültig.
    manager?.addEmphases(
        SearchEmphasis.makeEmphases(for: [NSRange(location: 5, length: 5)]),
        for: SearchEmphasis.groupID
    )

    // Das Dokument schrumpft (Rechteck-Backspace im Befund): Der gemerkte
    // Bereich zeigt jetzt hinter das Ende.
    textView.replaceCharacters(in: NSRange(location: 2, length: 8), with: "")
    #expect(textView.string == "01")

    // Der nächste Zeichenzyklus ruft genau das hier auf — ohne Clamp war
    // das der Absturz aus dem Crash-Report.
    manager?.updateLayerBackgrounds()
}

@Test("Der Edit-Wächter räumt die Trefferanzeige synchron beim ersten Textedit")
@MainActor
func editGuardClearsEmphasesOnTextChange() {
    let textView = makeTextView("0123456789")
    let manager = textView.emphasisManager

    // Wächter wie im Produkt installieren, danach Markierungen setzen.
    let guardian = SearchEmphasis.EditGuard(textView: textView)
    manager?.addEmphases(
        SearchEmphasis.makeEmphases(for: [NSRange(location: 5, length: 5)]),
        for: SearchEmphasis.groupID
    )
    #expect(manager?.getEmphases(for: SearchEmphasis.groupID).count == 1)

    // Der erste Edit macht alle gemerkten Bereiche veraltet — der Wächter
    // muss sie synchron (vor dem nächsten Zeichenzyklus) entfernen.
    textView.replaceCharacters(in: NSRange(location: 2, length: 8), with: "")
    #expect(manager?.getEmphases(for: SearchEmphasis.groupID).isEmpty == true)

    withExtendedLifetime(guardian) {}
}
