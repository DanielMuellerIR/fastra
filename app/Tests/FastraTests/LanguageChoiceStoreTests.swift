// LanguageChoiceStoreTests.swift
//
// Die manuelle Formatwahl aus der Fußzeile gehört zur DATEI und muss ein
// erneutes Öffnen überleben — besonders bei einer Datei ohne Endung, für die
// die Automatik nichts erkennen kann (Daniel-Befund 2026-08-06).

import Foundation
import Testing
import CodeEditLanguages
@testable import Fastra

private struct LanguageChoiceFixture {
    let suiteName = "fastra-languagechoice-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = testSuiteDefaults(named: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeStore() -> LanguageChoiceStore {
        LanguageChoiceStore(defaults: defaults)
    }
}

/// Eigener Temp-Ordner je Test. Die Verschiebe-Tests brauchen echte Dateien:
/// Der Schlüssel des Speichers ist der kanonische Pfad, und den gibt es nur
/// für vorhandene Dateien.
private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-languagechoice-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    return directory
}

@Suite("Gemerkte Formatwahl")
struct LanguageChoiceStoreTests {

    @Test("Wahl einer Datei ohne Endung überlebt einen Neustart")
    func choiceSurvivesRestart() {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        let url = URL(fileURLWithPath: "/tmp/fastra-tests/notiz-ohne-endung")
        let markdown = LanguageMenuSupport.Entry.grammar(.markdown).id

        fixture.makeStore().setChoiceID(markdown, for: url)

        #expect(fixture.makeStore().choiceID(for: url) == markdown)
    }

    @Test("„Automatisch“ löscht die gemerkte Wahl")
    func automaticRemovesTheChoice() {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        let url = URL(fileURLWithPath: "/tmp/fastra-tests/notiz")
        let store = fixture.makeStore()

        store.setChoiceID(LanguageMenuSupport.Entry.grammar(.markdown).id, for: url)
        store.setChoiceID(nil, for: url)

        #expect(store.choiceID(for: url) == nil)
        #expect(fixture.makeStore().choiceID(for: url) == nil)
    }

    @Test("Der Speicher wächst nicht unbegrenzt; zuletzt Benutztes bleibt")
    func storeStaysBounded() {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let choice = LanguageMenuSupport.Entry.grammar(.markdown).id
        let total = LanguageChoiceStore.maximumEntries + 25

        for index in 0..<total {
            store.setChoiceID(choice,
                              for: URL(fileURLWithPath: "/tmp/fastra-tests/datei-\(index)"))
        }

        let newest = URL(fileURLWithPath: "/tmp/fastra-tests/datei-\(total - 1)")
        let oldest = URL(fileURLWithPath: "/tmp/fastra-tests/datei-0")
        #expect(store.choiceID(for: newest) == choice)
        #expect(store.choiceID(for: oldest) == nil)
    }

    @Test("Zwei Fenster überschreiben ihre Wahlen nicht gegenseitig")
    func twoLiveStoresDoNotOverwriteEachOther() {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        // Beide Stores entstehen VOR der ersten Wahl — genau der Zustand
        // zweier gleichzeitig geöffneter Dokumentfenster (Review 2026-08-06).
        let windowA = fixture.makeStore()
        let windowB = fixture.makeStore()
        let markdown = LanguageMenuSupport.Entry.grammar(.markdown).id
        let json = LanguageMenuSupport.Entry.grammar(.json).id
        let fileA = URL(fileURLWithPath: "/tmp/fastra-tests/fenster-a")
        let fileB = URL(fileURLWithPath: "/tmp/fastra-tests/fenster-b")

        windowA.setChoiceID(markdown, for: fileA)
        windowB.setChoiceID(json, for: fileB)

        #expect(windowA.choiceID(for: fileA) == markdown)
        #expect(windowB.choiceID(for: fileB) == json)
        // Beide Fenster sehen auch die Wahl des jeweils anderen.
        #expect(windowB.choiceID(for: fileA) == markdown)
        #expect(windowA.choiceID(for: fileB) == json)
    }

    @Test("Umbenennen einer Datei nimmt die gemerkte Wahl mit")
    func renamingAFileMovesItsChoice() throws {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = fixture.makeStore()
        let markdown = LanguageMenuSupport.Entry.grammar(.markdown).id

        let source = directory.appendingPathComponent("notiz")
        let destination = directory.appendingPathComponent("protokoll")
        try Data().write(to: source)
        store.setChoiceID(markdown, for: source)

        try FileManager.default.moveItem(at: source, to: destination)
        store.moveChoices(from: source, to: destination)

        #expect(store.choiceID(for: destination) == markdown)
        #expect(store.choiceID(for: source) == nil)
    }

    @Test("Umbenennen eines Ordners nimmt auch geschlossene Dateien mit")
    func renamingAFolderMovesNestedChoices() throws {
        let fixture = LanguageChoiceFixture()
        defer { fixture.cleanUp() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = fixture.makeStore()
        let markdown = LanguageMenuSupport.Entry.grammar(.markdown).id

        let source = directory.appendingPathComponent("alt", isDirectory: true)
        let destination = directory.appendingPathComponent("neu", isDirectory: true)
        try FileManager.default.createDirectory(at: source,
                                                withIntermediateDirectories: true)
        // Die Datei liegt zwei Ebenen tief und ist NICHT geöffnet: Über einen
        // Tab wäre hier nichts nachzubessern (Review 2026-08-06).
        let nestedDirectory = source.appendingPathComponent("tief", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory,
                                                withIntermediateDirectories: true)
        let nested = nestedDirectory.appendingPathComponent("notiz")
        try Data().write(to: nested)
        store.setChoiceID(markdown, for: nested)

        try FileManager.default.moveItem(at: source, to: destination)
        store.moveChoices(from: source, to: destination)

        let moved = destination.appendingPathComponent("tief/notiz")
        #expect(store.choiceID(for: moved) == markdown)

        // Der alte Eintrag darf nicht daneben liegen bleiben — sonst belegt
        // er bis zur Größenbegrenzung Platz.
        let raw = try #require(
            fixture.defaults.data(forKey: LanguageChoiceStore.Keys.choices)
        )
        let payload = try JSONDecoder().decode(LanguageChoiceStore.Payload.self,
                                               from: raw)
        #expect(payload.choices.count == 1)
        #expect(payload.order.count == 1)
    }

    @Test("Jeder gemerkte Bezeichner findet seinen Menüeintrag zurück")
    func everyStoredIdentifierResolvesBack() {
        for entry in LanguageMenuSupport.selectableEntries {
            #expect(LanguageMenuSupport.entry(withID: entry.id) == entry)
        }
        #expect(LanguageMenuSupport.entry(withID: "grammar.gibtesnicht") == nil)
    }
}
