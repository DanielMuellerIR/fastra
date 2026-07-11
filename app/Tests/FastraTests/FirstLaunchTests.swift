import Foundation
import Testing
@testable import Fastra

// Tests für den Demo-Inhalt-beim-ersten-Start-Mechanismus.
//
// Hintergrund (Interview-Erkenntnis 4): Ein leerer Start-Zustand verhindert
// den Einstieg — der ALLERERSTE Start lädt deshalb einen Demo-Tab mit
// vorbelegtem E-Mail-Pattern. Jeder weitere Start beginnt wie ein normaler
// Editor: leerer unbenannter Tab, kein vorbelegtes Pattern.
//
// Alle Tests nutzen eine eigene UserDefaults-Suite (eindeutiger Name pro
// Test) statt `.standard` — sonst würden Testläufe das echte
// Erststart-Flag der App verbrauchen bzw. sich gegenseitig beeinflussen.

/// Frische, isolierte UserDefaults-Suite für genau einen Test.
/// Der Aufrufer räumt sie via `removePersistentDomain` wieder ab.
private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-firstlaunch-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

@Test("consumeFirstLaunch: erster Aufruf true, alle weiteren false")
func consumeFirstLaunch_firstTrueThenFalse() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(DemoData.consumeFirstLaunch(defaults: defaults) == true)
    #expect(DemoData.consumeFirstLaunch(defaults: defaults) == false)
    #expect(DemoData.consumeFirstLaunch(defaults: defaults) == false)
}

@Test("Workspace beim ersten Start: Demo-Tab + vorbelegtes Pattern")
@MainActor
func workspace_firstLaunch_loadsDemo() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    #expect(ws.tabs.count == 1)
    #expect(ws.tabs.first?.title == "contacts.md")
    // Der Demo-Inhalt muss wirklich geladen sein (nicht leer) …
    #expect(ws.tabs.first?.content.contains("anna.huber@gmail.com") == true)
    // … und das vorbelegte Pattern gehört als Paar dazu.
    #expect(ws.findPattern.isEmpty == false)
}

@Test("Workspace bei Folgestarts: leerer Tab, kein Pattern")
@MainActor
func workspace_secondLaunch_startsEmpty() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Erster Start „verbraucht" das Erststart-Flag …
    _ = Workspace(defaults: defaults)
    // … der zweite simuliert den nächsten App-Start.
    let second = Workspace(defaults: defaults)

    #expect(second.tabs.count == 1)
    #expect(second.tabs.first?.title == "Ohne Titel")
    #expect(second.tabs.first?.content.isEmpty == true)
    #expect(second.findPattern.isEmpty == true)
    #expect(second.replacePattern.isEmpty == true)
}
