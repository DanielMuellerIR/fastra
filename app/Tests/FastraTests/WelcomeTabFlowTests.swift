// WelcomeTabFlowTests.swift
//
// Sichert das Platzhalter-Modell des Willkommensbildschirms ab (2026-07-30,
// Firefox-Neuer-Tab-Muster; ersetzt den eigenen Willkommen-Tab vom
// 2026-07-12): Jeder unberührte leere Tab zeigt die Starthilfe über dem
// Editor; ⌘T legt daneben einen weiteren frischen Tab an, der sie ebenfalls
// zeigt; das erste getippte Zeichen blendet sie aus. Neue unbenannte Tabs
// tragen den lokalisierten Basisnamen mit Positionsnummer.

import Foundation
import Testing
@testable import Fastra

/// Frische, isolierte UserDefaults-Suite für genau einen Test.
private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-welcometab-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

/// Liefert einen Workspace im Folgestart-Zustand (ein unberührter leerer
/// Start-Tab), indem der erste Init das Erststart-Flag verbraucht und der
/// zweite den Folgestart simuliert.
@MainActor
private func makeWelcomeWorkspace() -> (Workspace, UserDefaults, String) {
    let (defaults, suite) = makeFreshDefaults()
    _ = Workspace(defaults: defaults)          // Erststart-Demo „verbrauchen"
    return (Workspace(defaults: defaults), defaults, suite)
}

@Test("Folgestart legt genau einen unberührten leeren Tab an, Platzhalter sichtbar")
@MainActor
func welcomeTab_folgestartShowsPlaceholder() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ws.tabs.count == 1)
    #expect(ws.tabs.first?.isPristineScratch == true)
    #expect(ws.isWelcomeScreen)
}

@Test("⌘T legt einen zweiten frischen Tab an — auch er zeigt den Platzhalter")
@MainActor
func welcomeTab_openNewTabKeepsFirstAndShowsPlaceholderAgain() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstID = ws.tabs[0].id

    ws.openNewTab()

    // Der erste Tab bleibt stehen; der neue ist aktiv.
    #expect(ws.tabs.count == 2)
    #expect(ws.tabs[0].id == firstID)
    #expect(ws.tabs[1].title == Workspace.untitledName(position: 2))
    #expect(ws.activeTabID == ws.tabs[1].id)
    // Firefox-Muster: Auch der frische zweite Tab ist unberührt leer und
    // zeigt deshalb den Willkommens-Platzhalter.
    #expect(ws.tabs[1].isPristineScratch)
    #expect(ws.isWelcomeScreen)
}

@Test("Das erste getippte Zeichen blendet den Platzhalter aus — Löschen bringt ihn zurück")
@MainActor
func welcomeTab_firstCharacterDismissesPlaceholder() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }

    ws.activeTabContent.wrappedValue = "a"
    #expect(!ws.isWelcomeScreen)

    // Bewusst zustandsfrei abgeleitet: Wird der Tab wieder exakt leer und
    // ungeändert, gilt er erneut als unberührt und die Starthilfe erscheint.
    ws.activeTabContent.wrappedValue = ""
    #expect(ws.tabs[0].isPristineScratch == ws.isWelcomeScreen)
}

@Test("Zweiter unbenannter Name folgt der Positionsnummer, erster ohne Nummer")
@MainActor
func welcomeTab_untitledNaming() {
    // Sprache-unabhängig über den Basisnamen prüfen (de: „Ohne Titel").
    let base = Workspace.untitledBaseName
    #expect(Workspace.untitledName(position: 1) == base)
    #expect(Workspace.untitledName(position: 2) == "\(base) 2")
    #expect(Workspace.untitledName(position: 3) == "\(base) 3")
}

@Test("Fensterschließen hinterlässt den Workspace im Startzustand")
@MainActor
func welcomeTab_prepareToCloseWindowResetsToStartState() {
    // SwiftUI hält die Szene des Hauptfensters samt Workspace am Leben und
    // kann sie nach dem Schließen wieder anzeigen (Dock-Klick). Bliebe der
    // Workspace nach `prepareToCloseWindow` bei null Tabs, erschiene dann ein
    // Fenster ohne Tabs mit tippbarer, aber ins Leere schreibender
    // Editorfläche (Daniel-Befund 2026-07-29).
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }

    let a = EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: false)
    let b = EditorTab(title: "b.txt", path: "/tmp", content: "y", isDirty: false)
    ws.tabs = [a, b]
    ws.activeTabID = a.id

    #expect(ws.prepareToCloseWindow())
    #expect(ws.tabs.count == 1)
    #expect(ws.tabs[0].isPristineScratch)
    #expect(ws.isWelcomeScreen)
    #expect(ws.activeTabID == ws.tabs[0].id)
}
