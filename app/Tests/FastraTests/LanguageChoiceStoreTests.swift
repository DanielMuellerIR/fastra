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
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeStore() -> LanguageChoiceStore {
        LanguageChoiceStore(defaults: defaults)
    }
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

    @Test("Jeder gemerkte Bezeichner findet seinen Menüeintrag zurück")
    func everyStoredIdentifierResolvesBack() {
        for entry in LanguageMenuSupport.selectableEntries {
            #expect(LanguageMenuSupport.entry(withID: entry.id) == entry)
        }
        #expect(LanguageMenuSupport.entry(withID: "grammar.gibtesnicht") == nil)
    }
}
