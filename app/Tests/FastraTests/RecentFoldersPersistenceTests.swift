// RecentFoldersPersistenceTests.swift
//
// Sichert ab, dass die Recent-Folders-Liste sich sauber in UserDefaults
// schreibt und beim Neustart wiederkommt. Jeder Test nutzt seinen
// EIGENEN UserDefaults-Suite-Namen, damit die globalen Defaults nicht
// gemüllt werden und Tests parallel sicher sind.

import Testing
import Foundation
@testable import Fastra

private func makeDefaults() -> UserDefaults {
    let suite = "fastra.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

@Test("Leere UserDefaults → Default-Liste mit drei Demo-Ordnern")
func load_returnsDefaultsWhenEmpty() {
    let d = makeDefaults()
    let loaded = RecentSearchFoldersStore.load(from: d)
    #expect(loaded.count == 3)
    #expect(loaded.first?.enabled == true)
}

@Test("Schreiben und Lesen ergibt dieselben Pfade und Enabled-Flags")
func save_thenLoad_roundtrip() {
    let d = makeDefaults()
    let entries = [
        SearchFolderEntry(path: "/Users/test/Foo", enabled: true),
        SearchFolderEntry(path: "/Users/test/Bar", enabled: false),
    ]
    RecentSearchFoldersStore.save(entries, to: d)
    let loaded = RecentSearchFoldersStore.load(from: d)
    #expect(loaded.count == 2)
    #expect(loaded[0].path == "/Users/test/Foo")
    #expect(loaded[0].enabled == true)
    #expect(loaded[1].path == "/Users/test/Bar")
    #expect(loaded[1].enabled == false)
}

@Test("Leere Liste wird auch persistiert (Default kommt NICHT zurück)")
func save_emptyList_loadsAsEmpty() {
    let d = makeDefaults()
    RecentSearchFoldersStore.save([], to: d)
    let loaded = RecentSearchFoldersStore.load(from: d)
    #expect(loaded.isEmpty)
}

@Test("UUIDs sind beim Laden frisch, NICHT identisch mit den gespeicherten")
func load_regeneratesIDs() {
    let d = makeDefaults()
    let original = SearchFolderEntry(path: "/x", enabled: true)
    RecentSearchFoldersStore.save([original], to: d)
    let loaded = RecentSearchFoldersStore.load(from: d).first!
    #expect(loaded.path == original.path)
    #expect(loaded.id != original.id)
}

@Test("Tilde-Pfade werden beim url-Zugriff expandiert")
func entry_urlExpandsTilde() {
    let entry = SearchFolderEntry(path: "~/Test", enabled: true)
    let path = entry.url.path
    #expect(!path.hasPrefix("~"), "Tilde wurde nicht expandiert: \(path)")
    #expect(path.contains("/Test"))
}
