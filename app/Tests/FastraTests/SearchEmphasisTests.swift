// SearchEmphasisTests.swift
//
// Tests für die pure Logik der Live-Trefferanzeige (Etappe 2 Wunschpaket
// 2026-07b): Cap-Planung und Sichtbarkeitsbedingung. Die echte Zeichnung
// (Emphasis-Layer in der TextView) prüft der Selbsttest `searchmark`.

import Foundation
import Testing
@testable import Fastra

private func ranges(_ count: Int) -> [NSRange] {
    (0..<count).map { NSRange(location: $0 * 10, length: 4) }
}

@Test("plan: unter dem Cap werden alle Ranges gezeichnet, kein Hinweis")
func plan_underCap() {
    let plan = SearchEmphasis.plan(matchRanges: ranges(5), totalMatches: 5, cap: 10)
    #expect(plan.ranges.count == 5)
    #expect(!plan.truncated)
}

@Test("plan: über dem Cap bleiben die ERSTEN N, truncated wird gesetzt")
func plan_overCap() {
    let plan = SearchEmphasis.plan(matchRanges: ranges(12), totalMatches: 12, cap: 10)
    #expect(plan.ranges.count == 10)
    #expect(plan.ranges.first?.location == 0)
    #expect(plan.ranges.last?.location == 90)
    #expect(plan.truncated)
}

@Test("plan: echte Gesamtzahl über den materialisierten Ranges → truncated")
func plan_truncatedByTotalMatches() {
    // Die Buffer-Suche materialisiert höchstens `defaultMaxMatches` Ranges,
    // zählt aber ehrlich weiter — der Hinweis muss auch dann erscheinen.
    let plan = SearchEmphasis.plan(matchRanges: ranges(10), totalMatches: 250, cap: 10)
    #expect(plan.ranges.count == 10)
    #expect(plan.truncated)
}

@Test("plan: leere Trefferliste → nichts zu zeichnen, kein Hinweis")
func plan_empty() {
    let plan = SearchEmphasis.plan(matchRanges: [], totalMatches: 0, cap: 10)
    #expect(plan.ranges.isEmpty)
    #expect(!plan.truncated)
}

@Test("shouldShow: nur Datei-Scope + offener Dialog + Text-Ansicht")
func shouldShow_conditions() {
    // Der einzige erlaubte Fall:
    #expect(SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .text))
    // Geschlossener Dialog räumt die Anzeige:
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: false, viewMode: .text))
    // Ordner-/Projekt-/Geöffnet-Scope markieren nur über die Trefferliste:
    #expect(!SearchEmphasis.shouldShow(scope: .folder, dialogOpen: true, viewMode: .text))
    #expect(!SearchEmphasis.shouldShow(scope: .project, dialogOpen: true, viewMode: .text))
    #expect(!SearchEmphasis.shouldShow(scope: .open, dialogOpen: true, viewMode: .text))
    // Vorschau/Hex zeigen keinen Editor-Text:
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .preview))
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .hex))
}

@Test("cap: entspricht dem Materialisierungs-Cap der Buffer-Suche")
func cap_matchesBufferSearch() {
    // Bewusste Kopplung: mehr als die materialisierten Treffer könnten gar
    // nicht gezeichnet werden — driftet der Cap, soll dieser Test es zeigen.
    #expect(SearchEmphasis.cap == BufferSearch.defaultMaxMatches)
}
