// SearchHistoryTests.swift
//
// Tests für den Such-Verlauf (K4) — reine Listen-Logik + Persistenz.

import Foundation
import Testing
@testable import Fastra

private func makeDefaults() -> UserDefaults {
    let suite = "fastra.tests.history.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

private func entry(_ find: String, _ replace: String = "") -> SearchHistoryEntry {
    SearchHistoryEntry(find: find, replace: replace)
}

@Test("Leere UserDefaults → leerer Verlauf")
func history_emptyByDefault() {
    #expect(SearchHistoryStore.load(from: makeDefaults()).isEmpty)
}

@Test("prepending: neues Paar landet oben")
func history_prependsOnTop() {
    let r = SearchHistoryStore.prepending(entry("b"), to: [entry("a")])
    #expect(r.map(\.find) == ["b", "a"])
}

@Test("prepending: identisches Paar (Find UND Replace) wird nicht dupliziert")
func history_dedupExactPair() {
    let r = SearchHistoryStore.prepending(entry("a", "x"),
                                          to: [entry("b"), entry("a", "x")])
    #expect(r.count == 2)
    #expect(r[0].find == "a" && r[0].replace == "x")
    #expect(r[1].find == "b")
}

@Test("prepending: gleicher Find, anderer Replace ist ein NEUER Eintrag")
func history_differentReplaceIsNewEntry() {
    let r = SearchHistoryStore.prepending(entry("a", "y"), to: [entry("a", "x")])
    #expect(r.count == 2)
}

@Test("prepending: leerer Find-String wird ignoriert")
func history_skipsEmptyFind() {
    let existing = [entry("a")]
    let r = SearchHistoryStore.prepending(entry(""), to: existing)
    #expect(r == existing)
}

@Test("prepending: Verlauf wird auf max gekürzt")
func history_capsAtMax() {
    let existing = (0..<15).map { entry("f\($0)") }
    let r = SearchHistoryStore.prepending(entry("neu"), to: existing, max: 15)
    #expect(r.count == 15)
    #expect(r.first?.find == "neu")
    #expect(!r.contains(where: { $0.find == "f14" }))
}

@Test("save → load Roundtrip erhält Find/Replace und Reihenfolge")
func history_roundtrip() {
    let d = makeDefaults()
    let entries = [entry("a", "x"), entry("b")]
    SearchHistoryStore.save(entries, to: d)
    let loaded = SearchHistoryStore.load(from: d)
    #expect(loaded.count == 2)
    #expect(loaded[0].find == "a" && loaded[0].replace == "x")
    #expect(loaded[1].find == "b" && loaded[1].replace == "")
}
