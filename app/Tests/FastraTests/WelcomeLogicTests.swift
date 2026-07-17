// WelcomeLogicTests.swift
//
// Tests für die Sichtbarkeits-Logik des Willkommensbildschirms
// (Projekt- & Git-Ausbau, Etappe 1; per-Tab-Modell seit 2026-07-12). Die
// Bedingung lebt pur in WelcomeLogic.shouldShow — die View wertet sie nur aus.

import Foundation
import Testing
@testable import Fastra

@Test("Aktiver Willkommen-Tab → Willkommen sichtbar")
func welcome_showsWhenWelcomeTabActive() {
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                        isWelcome: true)
    #expect(WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Aktiver normaler leerer Tab (z.B. zweiter Tab nach ⌘T) → Editor")
func welcome_hiddenForPlainEmptyTab() {
    // Ein leerer Editor-Tab OHNE isWelcome (der neben dem Willkommen-Tab
    // entsteht) zeigt den Editor, nicht die Willkommensseite.
    let tab = EditorTab(title: "Ohne Titel 2", path: "—")
    #expect(!WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Aktiver Tab mit Inhalt → Editor")
func welcome_hiddenWithContent() {
    let tab = EditorTab(title: "contacts.md", path: "Demo", content: "Nachname, Vorname")
    #expect(!WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Aktiver Tab mit Datei-URL → Editor")
func welcome_hiddenWithFileTab() {
    var tab = EditorTab(title: "a.txt", path: "/x")
    tab.url = URL(fileURLWithPath: "/x/a.txt")
    #expect(!WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Kein aktiver Tab → Editor (kein Willkommen)")
func welcome_hiddenWithoutActiveTab() {
    #expect(!WelcomeLogic.shouldShow(activeTab: nil))
}

// MARK: - ⌘N im reinen Willkommenszustand (Wunschpaket 2026-07, Etappe 1)

@Test("⌘N: einziges Fenster zeigt nur Willkommen → wirkt wie ⌘T")
func newWindowCommand_opensTabInPureWelcomeState() {
    let welcome = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                            isWelcome: true)
    #expect(WelcomeLogic.newWindowCommandOpensTab(
        tabs: [welcome], visibleDocumentWindows: 1
    ))
}

@Test("⌘N: zweites Dokumentfenster offen → normales Fenster-Kommando")
func newWindowCommand_opensWindowWithSecondWindow() {
    let welcome = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                            isWelcome: true)
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [welcome], visibleDocumentWindows: 2
    ))
}

@Test("⌘N: neben Willkommen existiert ein weiterer Tab → Fenster-Kommando")
func newWindowCommand_opensWindowWithExtraTab() {
    let welcome = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                            isWelcome: true)
    let editor = EditorTab(title: "Ohne Titel 2", path: "—")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [welcome, editor], visibleDocumentWindows: 1
    ))
}

@Test("⌘N: einzelner normaler Tab (kein Willkommen) → Fenster-Kommando")
func newWindowCommand_opensWindowForPlainTab() {
    let editor = EditorTab(title: "a.txt", path: "/x")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [editor], visibleDocumentWindows: 1
    ))
}

@Test("Projektliste zeigt nur vollständig passende Zeilen")
func welcome_recentProjectsFitAvailableHeight() {
    #expect(WelcomeLayout.visibleRecentProjectCount(
        availableHeight: 800, uiScale: 1.7, total: 10
    ) == 4)
    #expect(WelcomeLayout.visibleRecentProjectCount(
        availableHeight: 350, uiScale: 1.7, total: 10
    ) == 0)
    #expect(WelcomeLayout.visibleRecentProjectCount(
        availableHeight: 800, uiScale: 1, total: 3
    ) == 3)
}
