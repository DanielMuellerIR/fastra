// WelcomeLogicTests.swift
//
// Tests für die Sichtbarkeits-Logik des Willkommensbildschirms
// (Projekt- & Git-Ausbau, Etappe 1). Die Bedingung lebt pur in
// WelcomeLogic.shouldShow — die View wertet sie nur aus.

import Foundation
import Testing
@testable import Fastra

@Test("Jungfräulicher Start (ein leerer unbenannter Tab) → Willkommen sichtbar")
func welcome_showsOnPristineStart() {
    let tabs = [EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")]
    #expect(WelcomeLogic.shouldShow(tabs: tabs, hasProject: false, dismissed: false))
}

@Test("Mehrere leere Scratch-Tabs → weiterhin sichtbar")
func welcome_showsWithMultiplePristineTabs() {
    let tabs = [
        EditorTab(title: "Ohne Titel", path: "—"),
        EditorTab(title: "untitled-2.txt", path: "—"),
    ]
    #expect(WelcomeLogic.shouldShow(tabs: tabs, hasProject: false, dismissed: false))
}

@Test("Tab mit Inhalt (z.B. Demo-Tab des Erststarts) → Editor hat Vorrang")
func welcome_hiddenWithContent() {
    let tabs = [EditorTab(title: "contacts.md", path: "Demo", content: "Nachname, Vorname")]
    #expect(!WelcomeLogic.shouldShow(tabs: tabs, hasProject: false, dismissed: false))
}

@Test("Tab mit Datei-URL → verborgen")
func welcome_hiddenWithFileTab() {
    var tab = EditorTab(title: "a.txt", path: "/x")
    tab.url = URL(fileURLWithPath: "/x/a.txt")
    #expect(!WelcomeLogic.shouldShow(tabs: [tab], hasProject: false, dismissed: false))
}

@Test("Dirty-Tab (getippt, noch leer gespeichert) → verborgen")
func welcome_hiddenWithDirtyTab() {
    var tab = EditorTab(title: "Ohne Titel", path: "—")
    tab.isDirty = true
    #expect(!WelcomeLogic.shouldShow(tabs: [tab], hasProject: false, dismissed: false))
}

@Test("Ladender Tab → verborgen (Spinner soll sichtbar sein)")
func welcome_hiddenWhileLoading() {
    var tab = EditorTab(title: "big.txt", path: "/x")
    tab.isLoading = true
    #expect(!WelcomeLogic.shouldShow(tabs: [tab], hasProject: false, dismissed: false))
}

@Test("Projekt geladen → verborgen (Dateibaum + Editor haben Vorrang)")
func welcome_hiddenWithProject() {
    let tabs = [EditorTab(title: "Ohne Titel", path: "—")]
    #expect(!WelcomeLogic.shouldShow(tabs: tabs, hasProject: true, dismissed: false))
}

@Test("Aktiv weggeklickt (Neue-Datei-Button, Tab-Klick, ⌘T) → verborgen")
func welcome_hiddenWhenDismissed() {
    let tabs = [EditorTab(title: "Ohne Titel", path: "—")]
    #expect(!WelcomeLogic.shouldShow(tabs: tabs, hasProject: false, dismissed: true))
}
