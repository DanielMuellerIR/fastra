// WelcomeTabFlowTests.swift
//
// Sichert das per-Tab-Willkommen-Modell (2026-07-12) ab: Der Willkommen-Tab
// ist ein eigener Tab, der bei ⌘T/„Neue Datei" bestehen bleibt — daneben
// entsteht ein echter Editor-Tab, in den gesprungen wird. Neue unbenannte
// Tabs tragen den lokalisierten Basisnamen mit Positionsnummer.

import Foundation
import Testing
@testable import Fastra

/// Frische, isolierte UserDefaults-Suite für genau einen Test.
private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-welcometab-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

/// Liefert einen Workspace im Folgestart-Zustand (Willkommen-Tab), indem der
/// erste Init das Erststart-Flag verbraucht und der zweite den Folgestart
/// simuliert.
@MainActor
private func makeWelcomeWorkspace() -> (Workspace, UserDefaults, String) {
    let (defaults, suite) = makeFreshDefaults()
    _ = Workspace(defaults: defaults)          // Erststart-Demo „verbrauchen"
    return (Workspace(defaults: defaults), defaults, suite)
}

@Test("Folgestart legt genau einen Willkommen-Tab an, Willkommen sichtbar")
@MainActor
func welcomeTab_folgestartHasWelcomeTab() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ws.tabs.count == 1)
    #expect(ws.tabs.first?.isWelcome == true)
    #expect(ws.isWelcomeScreen)
}

@Test("⌘T lässt den Willkommen-Tab stehen und springt in den neuen Editor-Tab")
@MainActor
func welcomeTab_openNewTabKeepsWelcomeAndJumps() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let welcomeID = ws.tabs[0].id

    ws.openNewTab()

    // Willkommen-Tab bleibt als eigener Tab „Willkommen".
    #expect(ws.tabs.count == 2)
    #expect(ws.tabs[0].id == welcomeID)
    #expect(ws.tabs[0].isWelcome == true)
    // Zweiter Tab: normaler Editor-Tab mit lokalisiertem Namen an Position 2.
    #expect(ws.tabs[1].isWelcome == false)
    #expect(ws.tabs[1].title == Workspace.untitledName(position: 2))
    // In den zweiten Tab gesprungen → Editor sichtbar, nicht Willkommen.
    #expect(ws.activeTabID == ws.tabs[1].id)
    #expect(!ws.isWelcomeScreen)

    // Zurück auf den Willkommen-Tab → Willkommen wieder sichtbar.
    ws.activeTabID = welcomeID
    #expect(ws.isWelcomeScreen)
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

@Test("dismissWelcomeTab wandelt den Willkommen-Tab in ein normales Dokument")
@MainActor
func welcomeTab_dismissConverts() {
    let (ws, defaults, suite) = makeWelcomeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }

    ws.dismissWelcomeTab()

    #expect(ws.tabs.count == 1)
    #expect(ws.tabs[0].isWelcome == false)
    #expect(!ws.isWelcomeScreen)
    // Unterbau-Titel bleibt der lokalisierte Basisname (jetzt sichtbar).
    #expect(ws.tabs[0].title == Workspace.untitledBaseName)
}

@Test("Fensterschließen hinterlässt den Workspace im Willkommens-Zustand")
@MainActor
func welcomeTab_prepareToCloseWindowResetsToWelcome() {
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
    #expect(ws.tabs[0].isWelcome)
    #expect(ws.isWelcomeScreen)
    #expect(ws.activeTabID == ws.tabs[0].id)
}
