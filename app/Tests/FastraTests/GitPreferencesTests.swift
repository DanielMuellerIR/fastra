import Foundation
import Testing
@testable import Fastra

private func isolatedGitDefaults() -> UserDefaults {
    let name = "FastraTests.GitPreferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Git-Präferenzen")
struct GitPreferencesTests {
    @Test("Frische Installation verwendet sichere Defaults")
    func freshDefaults() {
        let value = GitPreferencesStore(defaults: isolatedGitDefaults()).load()
        #expect(value.automaticFetchDecision == .ask)
        #expect(value.fetchIntervalSeconds == 180)
        #expect(value.fetchOnActivation)
        #expect(value.remoteScope == .relevant)
        #expect(!value.prune)
        #expect(value.pullStrategy == .unselected)
    }

    @Test("Alle Werte werden typisiert gespeichert und geladen")
    func roundTrip() {
        let store = GitPreferencesStore(defaults: isolatedGitDefaults())
        let expected = GitPreferences(automaticFetchDecision: .automatic,
                                     fetchIntervalSeconds: 600,
                                     fetchOnActivation: false,
                                     remoteScope: .all,
                                     prune: true,
                                     pullStrategy: .rebase)
        store.save(expected)
        #expect(store.load() == expected)
    }

    @Test("Intervall wird beim Lesen und Schreiben auf 60 bis 3600 begrenzt")
    func intervalClamp() {
        let defaults = isolatedGitDefaults()
        defaults.set(1, forKey: GitPreferencesStore.Keys.interval)
        #expect(GitPreferencesStore(defaults: defaults).load().fetchIntervalSeconds == 60)

        let store = GitPreferencesStore(defaults: defaults)
        var value = GitPreferences()
        value.fetchIntervalSeconds = 99_999
        store.save(value)
        #expect(defaults.integer(forKey: GitPreferencesStore.Keys.interval) == 3600)
    }

    @Test("Experimentelle boolesche Einstellung wird migrationssicher gelesen")
    func legacyMigration() {
        let defaults = isolatedGitDefaults()
        defaults.set(true, forKey: GitPreferencesStore.Keys.legacyAutoFetch)
        defaults.set(300, forKey: GitPreferencesStore.Keys.legacyInterval)
        let value = GitPreferencesStore(defaults: defaults).load()
        #expect(value.automaticFetchDecision == .automatic)
        #expect(value.fetchIntervalSeconds == 300)
        #expect(defaults.object(forKey: GitPreferencesStore.Keys.legacyAutoFetch) != nil)
    }

    @Test("Ungültige neue Werte fallen einzeln auf Defaults zurück")
    func invalidValues() {
        let defaults = isolatedGitDefaults()
        defaults.set("future", forKey: GitPreferencesStore.Keys.decision)
        defaults.set("future", forKey: GitPreferencesStore.Keys.remoteScope)
        defaults.set("future", forKey: GitPreferencesStore.Keys.pullStrategy)
        let value = GitPreferencesStore(defaults: defaults).load()
        #expect(value.automaticFetchDecision == .ask)
        #expect(value.remoteScope == .relevant)
        #expect(value.pullStrategy == .unselected)
    }

    @Test("Fremde Defaults bleiben unverändert")
    func unrelatedDefaultsRemain() {
        let defaults = isolatedGitDefaults()
        defaults.set("keep", forKey: "editor.unrelated")
        GitPreferencesStore(defaults: defaults).save(GitPreferences())
        #expect(defaults.string(forKey: "editor.unrelated") == "keep")
    }

    @Test("Aufgeschobene Erstfrage wird persistent gespeichert und gezielt zurückgesetzt")
    func promptDeferralReset() {
        let defaults = isolatedGitDefaults()
        let store = GitPreferencesStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000)
        store.deferAutomaticFetchPrompt(from: now)
        #expect(store.promptDeferredUntil
                == now.addingTimeInterval(GitFetchPromptPolicy.deferral))
        store.clearAutomaticFetchPromptDeferral()
        #expect(store.promptDeferredUntil == nil)
    }
}
