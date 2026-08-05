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

@Test("shouldShow: jeder Such-Scope bei offenem Dialog und Text-Ansicht")
func shouldShow_conditions() {
    #expect(SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .text))
    #expect(SearchEmphasis.shouldShow(scope: .folder, dialogOpen: true, viewMode: .text))
    #expect(SearchEmphasis.shouldShow(scope: .project, dialogOpen: true, viewMode: .text))
    #expect(SearchEmphasis.shouldShow(scope: .open, dialogOpen: true, viewMode: .text))
    // Geschlossener Dialog räumt die Anzeige:
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: false, viewMode: .text))
    // Vorschau/Hex zeigen keinen Editor-Text:
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .preview))
    #expect(!SearchEmphasis.shouldShow(scope: .file, dialogOpen: true, viewMode: .hex))
}

@MainActor
@Test("Datei-Scope verwendet die Treffer des aktiven Buffers")
func source_fileUsesBufferMatches() {
    let match = BufferSearch.find(
        in: "FUND",
        options: SearchOptions(find: "FUND", replace: "", isRegex: false)
    ).matches[0]
    let tab = EditorTab(title: "Aktiv.txt", path: "—", content: "FUND")
    let source = SearchEmphasis.source(
        scope: .file, activeTab: tab,
        bufferMatches: [match], bufferTotalMatches: 3,
        folderResults: [], openResults: []
    )
    #expect(source == .init(matches: [match], totalMatches: 3))
}

@MainActor
@Test("Ordner-Scope markiert nur Treffer derselben sauberen Dateibasis")
func source_folderRequiresMatchingSnapshot() throws {
    let url = URL(fileURLWithPath: "/tmp/fastra-search-emphasis.txt")
    let data = Data("FUND".utf8)
    let snapshot = FileSnapshot(data: data, identity: nil)
    let match = BufferSearch.find(
        in: "FUND",
        options: SearchOptions(find: "FUND", replace: "", isRegex: false)
    ).matches[0]
    let options = SearchOptions(find: "FUND", replace: "", isRegex: false)
    let result = FolderSearch.PerFileResult(
        url: url, matches: [match], totalMatches: 1, skipped: nil,
        snapshot: snapshot, searchOptions: options
    )
    let clean = EditorTab(title: "Aktiv.txt", path: url.path, url: url,
                          content: "FUND", diskSnapshot: snapshot)
    #expect(SearchEmphasis.source(
        scope: .folder, activeTab: clean,
        bufferMatches: [], bufferTotalMatches: 0,
        folderResults: [result], openResults: []
    )?.matches == [match])

    var dirty = clean
    dirty.isDirty = true
    #expect(SearchEmphasis.source(
        scope: .folder, activeTab: dirty,
        bufferMatches: [], bufferTotalMatches: 0,
        folderResults: [result], openResults: []
    ) == nil)

    var changed = clean
    changed.diskSnapshot = FileSnapshot(data: Data("anders".utf8), identity: nil)
    #expect(SearchEmphasis.source(
        scope: .project, activeTab: changed,
        bufferMatches: [], bufferTotalMatches: 0,
        folderResults: [result], openResults: []
    ) == nil)
}

@MainActor
@Test("Geöffnet-Scope verwendet nur die Treffer des aktiven Tabs")
func source_openUsesActiveTab() {
    let first = EditorTab(title: "Eins", path: "—", content: "FUND")
    let second = EditorTab(title: "Zwei", path: "—", content: "FUND")
    let match = BufferSearch.find(
        in: "FUND",
        options: SearchOptions(find: "FUND", replace: "", isRegex: false)
    ).matches[0]
    let results = [
        OpenTabsSearch.TabHits(id: first.id, title: first.title,
                               matches: [match], totalMatches: 1),
        OpenTabsSearch.TabHits(id: second.id, title: second.title,
                               matches: [], totalMatches: 4),
    ]
    #expect(SearchEmphasis.source(
        scope: .open, activeTab: second,
        bufferMatches: [], bufferTotalMatches: 0,
        folderResults: [], openResults: results
    ) == .init(matches: [], totalMatches: 4))
}

@Test("cap: entspricht dem Materialisierungs-Cap der Buffer-Suche")
func cap_matchesBufferSearch() {
    // Bewusste Kopplung: mehr als die materialisierten Treffer könnten gar
    // nicht gezeichnet werden — driftet der Cap, soll dieser Test es zeigen.
    #expect(SearchEmphasis.cap == BufferSearch.defaultMaxMatches)
}
