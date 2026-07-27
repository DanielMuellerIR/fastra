// EditorScrollMemoryTests.swift
//
// Der sichtbare Ausschnitt gehört zum Tab, nicht zum Editor: Beim Tab-Wechsel
// wird der eigentliche Editor per `.id` neu erzeugt und startet am
// Dateianfang. Ohne gemerkten Ausschnitt riss CESEs „Einfügemarke sichtbar
// machen" die Cursorzeile in die oberste Bildschirmzeile (Daniel-Befund
// 2026-07-27). Die reine Merk-Logik ist hier geprüft; dass der Ausschnitt im
// echten Fenster zurückkommt, prüft `-selftest tabscroll`.

import AppKit
import Testing
@testable import Fastra

@Test("Scroll-Memory gibt den Ausschnitt des Ziel-Tabs zurück")
func scrollMemoryRestoresPerTab() {
    var memory = EditorScrollMemory()
    let tabA = UUID()
    let tabB = UUID()

    // In A gescrollt, dann nach B gewechselt: B ist unbekannt → nil, und CESEs
    // Normalverhalten bleibt unangetastet.
    #expect(memory.switchTab(from: tabA, currentOffset: CGPoint(x: 0, y: 420),
                             to: tabB) == nil)
    // Zurück zu A: der Ausschnitt von vorher.
    #expect(memory.switchTab(from: tabB, currentOffset: CGPoint(x: 0, y: 0),
                             to: tabA) == CGPoint(x: 0, y: 420))
    // B war inzwischen oben — und bleibt es.
    #expect(memory.offset(for: tabB) == CGPoint(x: 0, y: 0))
}

@Test("Ohne Tab-ID oder Wert wird nichts gemerkt")
func scrollMemoryIgnoresIncompleteInput() {
    var memory = EditorScrollMemory()
    let tab = UUID()
    memory.remember(nil, for: tab)
    #expect(memory.offset(for: tab) == nil)
    memory.remember(CGPoint(x: 0, y: 99), for: nil)
    #expect(memory.offset(for: nil) == nil)
    memory.remember(CGPoint(x: 0, y: 99), for: tab)
    #expect(memory.offset(for: tab) == CGPoint(x: 0, y: 99))
}

@Test("Der zuletzt gemerkte Ausschnitt gewinnt")
func scrollMemoryKeepsLatestOffset() {
    var memory = EditorScrollMemory()
    let tab = UUID()
    memory.remember(CGPoint(x: 0, y: 100), for: tab)
    memory.remember(CGPoint(x: 0, y: 250), for: tab)
    #expect(memory.offset(for: tab) == CGPoint(x: 0, y: 250))
}
