import Foundation
import Testing
@testable import Fastra

// Tests für den vertrauenswürdigen Startzustand einer frischen Installation.
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

@Test("Workspace beim ersten Start: Willkommen ohne fremd wirkende Demodaten")
@MainActor
func workspace_firstLaunch_startsWithWelcome() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    #expect(ws.tabs.count == 1)
    #expect(ws.tabs.first?.title == Workspace.untitledBaseName)
    #expect(ws.tabs.first?.isWelcome == true)
    #expect(ws.tabs.first?.content.isEmpty == true)
    #expect(ws.findPattern.isEmpty == true)
    #expect(ws.replacePattern.isEmpty == true)
}

@Test("Workspace bei Folgestarts: leerer Tab, kein Pattern")
@MainActor
func workspace_secondLaunch_startsEmpty() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Erster Start …
    _ = Workspace(defaults: defaults)
    // … und der zweite simuliert den nächsten App-Start.
    let second = Workspace(defaults: defaults)

    #expect(second.tabs.count == 1)
    // Folgestart legt den Willkommen-Tab an; sein Unterbau-Titel ist der
    // lokalisierte Basisname (de: „Ohne Titel", sonst „Untitled").
    #expect(second.tabs.first?.title == Workspace.untitledBaseName)
    #expect(second.tabs.first?.isWelcome == true)
    #expect(second.tabs.first?.content.isEmpty == true)
    #expect(second.findPattern.isEmpty == true)
    #expect(second.replacePattern.isEmpty == true)
}
