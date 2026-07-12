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
