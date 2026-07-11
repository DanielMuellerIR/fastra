// RecentFilesStoreTests.swift
//
// Tests für „Zuletzt benutzte Dateien" (K2) — reine Listen-Logik +
// UserDefaults-Persistenz mit isolierter Suite pro Test.

import Foundation
import Testing
@testable import Fastra

private func makeDefaults() -> UserDefaults {
    let suite = "fastra.tests.recentfiles.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

@Test("Leere UserDefaults → leere Liste")
func recentFiles_emptyByDefault() {
    #expect(RecentFilesStore.load(from: makeDefaults()).isEmpty)
}

@Test("prepending: neuer Pfad landet oben")
func recentFiles_prependsOnTop() {
    let result = RecentFilesStore.prepending("/x/b.txt", to: ["/x/a.txt"])
    #expect(result == ["/x/b.txt", "/x/a.txt"])
}

@Test("prepending: vorhandener Pfad wandert nach oben statt zu duplizieren")
func recentFiles_movesExistingToTop() {
    let result = RecentFilesStore.prepending("/x/a.txt", to: ["/x/b.txt", "/x/a.txt", "/x/c.txt"])
    #expect(result == ["/x/a.txt", "/x/b.txt", "/x/c.txt"])
}

@Test("prepending: tilde-expandierter Pfad gilt als gleich (kein Duplikat)")
func recentFiles_dedupTildeExpanded() {
    let home = NSHomeDirectory()
    let result = RecentFilesStore.prepending("~/doc.txt", to: ["\(home)/doc.txt"])
    // Beide bezeichnen dieselbe Datei → nur ein Eintrag.
    #expect(result.count == 1)
    #expect(result.first == "~/doc.txt")
}

@Test("prepending: Liste wird auf max gekürzt (älteste fallen raus)")
func recentFiles_capsAtMax() {
    let existing = (0..<10).map { "/x/file\($0).txt" }
    let result = RecentFilesStore.prepending("/x/new.txt", to: existing, max: 10)
    #expect(result.count == 10)
    #expect(result.first == "/x/new.txt")
    // file9 (der vorher letzte) ist rausgefallen.
    #expect(!result.contains("/x/file9.txt"))
}

@Test("save → load Roundtrip erhält Reihenfolge")
func recentFiles_roundtrip() {
    let d = makeDefaults()
    let paths = ["/x/a.txt", "/x/b.txt"]
    RecentFilesStore.save(paths, to: d)
    #expect(RecentFilesStore.load(from: d) == paths)
}
