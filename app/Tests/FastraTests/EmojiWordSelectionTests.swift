// EmojiWordSelectionTests.swift
//
// Regressionstest für den build.sh-Patch 4o („Doppelklick auf Symbole"):
// Upstreams `findWordBoundary` kennt nur Bezeichner, Leerraum, Zeilenenden und
// Satzzeichen. Ein Doppelklick auf ein Emoji oder ein Symbol markierte deshalb
// gar nichts (Daniel-Befund 2026-07-27). Geprüft wird das reale Verhalten von
// `selectWord(_:)`, nicht die Patch-Zeile.

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

@MainActor
private func selection(in text: String, doubleClickAt location: Int) -> NSRange {
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    textView.layoutManager.layoutLines()
    textView.selectionManager.setSelectedRange(NSRange(location: location, length: 0))
    textView.selectWord(nil)
    return textView.selectionManager.textSelections.first?.range
        ?? NSRange(location: NSNotFound, length: 0)
}

@Test("Doppelklick markiert ein Emoji mit Variantenselektor vollständig")
@MainActor
func doubleClickSelectsEmojiWithVariationSelector() {
    // "vor ⏸️ nach": Basiszeichen bei 4, Variantenselektor bei 5.
    let text = "vor \u{23F8}\u{FE0F} nach"
    #expect(selection(in: text, doubleClickAt: 4) == NSRange(location: 4, length: 2))
    // Auch ein Klick, der auf dem Variantenselektor landet, markiert den
    // ganzen Cluster statt ihn zu zerlegen.
    #expect(selection(in: text, doubleClickAt: 5) == NSRange(location: 4, length: 2))
}

@Test("Doppelklick markiert Surrogatpaare und ZWJ-Familien als eine Einheit")
@MainActor
func doubleClickSelectsComposedEmoji() {
    let music = "Ton 🎶 Ende"                       // Surrogatpaar
    #expect(selection(in: music, doubleClickAt: 4) == NSRange(location: 4, length: 2))

    let family = "wir 👨‍👩‍👧 hier"                     // ZWJ-Sequenz, 8 UTF-16-Einheiten
    let expected = NSRange(location: 4, length: ("👨‍👩‍👧" as NSString).length)
    #expect(selection(in: family, doubleClickAt: 4) == expected)
    // Ein Klick in die Mitte der Sequenz darf sie nicht auseinanderreißen.
    #expect(selection(in: family, doubleClickAt: 6) == expected)
}

@Test("Doppelklick markiert auch ein nacktes Symbol ohne Variantenselektor")
@MainActor
func doubleClickSelectsBareSymbol() {
    // Genau der Fall aus Daniels Sprechskript: `⏸` ohne U+FE0F.
    let text = "Pause \u{23F8} weiter"
    #expect(selection(in: text, doubleClickAt: 6) == NSRange(location: 6, length: 1))
    let arrow = "links \u{2192} rechts"
    #expect(selection(in: arrow, doubleClickAt: 6) == NSRange(location: 6, length: 1))
}

@Test("Wörter, Leerraum und Satzzeichen bleiben unverändert")
@MainActor
func doubleClickKeepsWordBehaviour() {
    let text = "alpha beta, gamma"
    #expect(selection(in: text, doubleClickAt: 0) == NSRange(location: 0, length: 5))
    #expect(selection(in: text, doubleClickAt: 7) == NSRange(location: 6, length: 4))
    // Das Komma ist Satzzeichen — upstream-Verhalten, hier nur abgesichert.
    #expect(selection(in: text, doubleClickAt: 10) == NSRange(location: 10, length: 1))
    // Leerraum bleibt Leerraum-Auswahl.
    #expect(selection(in: text, doubleClickAt: 5) == NSRange(location: 5, length: 1))
}

@Test("Doppelklick auf die rechte Zellenhälfte rückt clusterweise zurück")
@MainActor
func doubleClickRightHalfStepsBackByComposedCluster() {
    // Regressionstest für den build.sh-Patch 4u (Review 2026-08-02): Die
    // Auswahlbasis rückte um genau EINE UTF-16-Einheit zurück und landete
    // bei zerlegtem Unicode mitten im Cluster. Geprüft wird der echte
    // Mausweg (mouseDown mit clickCount 2) in einem echten Fenster.
    let text = "Wort🎶 Ende"                    // Surrogatpaar an Offset 4–5
    let textView = CodeEditTextView.TextView(string: text)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = textView
    textView.layoutManager.layoutLines()
    guard let emojiRect = textView.layoutManager.rectForOffset(4),
          emojiRect.width > 0 else {
        Issue.record("Emoji-Zelle wurde nicht ausgelegt")
        return
    }
    // Rechte Hälfte der Emoji-Zelle: `textOffsetAtPoint` rundet auf den
    // Offset HINTER dem Cluster; die Rückrechnung muss an dessen Anfang.
    let clickPoint = NSPoint(x: emojiRect.maxX - max(1, emojiRect.width * 0.25),
                             y: emojiRect.midY)
    let pointInWindow = textView.convert(clickPoint, to: nil)
    guard let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: pointInWindow, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 2, pressure: 1
    ) else {
        Issue.record("Doppelklick-Event nicht baubar")
        return
    }
    textView.mouseDown(with: event)
    let selected = textView.selectionManager.textSelections.first?.range
    #expect(selected == NSRange(location: 4, length: 2))
}
