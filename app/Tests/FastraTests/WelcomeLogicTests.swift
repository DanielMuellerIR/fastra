// WelcomeLogicTests.swift
//
// Tests für die Sichtbarkeits-Logik des Willkommens-Platzhalters
// (Platzhalter-Modell seit 2026-07-30, Firefox-Neuer-Tab-Muster: JEDER
// unberührte leere Tab zeigt die Starthilfe über dem Editor — auch in
// Fenstern mit geladenem Projekt, Daniel-Befund 2026-07-30; das erste
// Zeichen blendet sie aus). Die Bedingung lebt pur in
// WelcomeLogic.shouldShow — die View wertet sie nur aus.

import Foundation
import Testing
@testable import Fastra

@Test("Unberührter leerer Tab ohne Projekt → Platzhalter sichtbar")
func welcome_showsForPristineScratchTab() {
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    #expect(tab.isPristineScratch)
    #expect(WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Auch der zweite frische ⌘T-Tab zeigt den Platzhalter")
func welcome_showsForEveryFreshTab() {
    // Firefox-Muster: Jeder neue leere Tab ist ein „neuer Tab" mit
    // Starthilfe — nicht nur der erste des Fensters.
    let tab = EditorTab(title: "Ohne Titel 2", path: "—")
    #expect(WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Aktiver Tab mit Inhalt → Editor ohne Platzhalter")
func welcome_hiddenWithContent() {
    let tab = EditorTab(title: "contacts.md", path: "Demo", content: "Nachname, Vorname")
    #expect(!WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Aktiver Tab mit Datei-URL → Editor ohne Platzhalter")
func welcome_hiddenWithFileTab() {
    var tab = EditorTab(title: "a.txt", path: "/x")
    tab.url = URL(fileURLWithPath: "/x/a.txt")
    #expect(!WelcomeLogic.shouldShow(activeTab: tab))
}

@Test("Dirty oder ladend → kein Platzhalter")
func welcome_hiddenForDirtyOrLoadingTab() {
    let dirty = EditorTab(title: "Ohne Titel", path: "—", content: "", isDirty: true)
    #expect(!WelcomeLogic.shouldShow(activeTab: dirty))
    let loading = EditorTab(title: "a.txt", path: "/x", content: "",
                            isDirty: false, isLoading: true)
    #expect(!WelcomeLogic.shouldShow(activeTab: loading))
}

@Test("Kein aktiver Tab (= gar kein Tab) → Willkommen statt Geister-Editor")
func welcome_shownWithoutAnyTab() {
    // `activeTab == nil` heißt „das Fenster hat überhaupt keine Tabs" — ein
    // kaputter Zwischenzustand (Daniel-Befund 2026-07-29). Lieber die
    // Starthilfe als eine tippbare Fläche, deren Eingaben in kein Dokument
    // fließen.
    #expect(WelcomeLogic.shouldShow(activeTab: nil))
}

// MARK: - ⌘N im reinen Startzustand (Wunschpaket 2026-07, Etappe 1)

@Test("⌘N: einziges Fenster im reinen Startzustand → wirkt wie ⌘T")
func newWindowCommand_opensTabInPureStartState() {
    let scratch = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    #expect(WelcomeLogic.newWindowCommandOpensTab(
        tabs: [scratch], hasProject: false, visibleDocumentWindows: 1
    ))
}

@Test("⌘N: zweites Dokumentfenster offen → normales Fenster-Kommando")
func newWindowCommand_opensWindowWithSecondWindow() {
    let scratch = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [scratch], hasProject: false, visibleDocumentWindows: 2
    ))
}

@Test("⌘N: neben dem Start-Tab existiert ein weiterer Tab → Fenster-Kommando")
func newWindowCommand_opensWindowWithExtraTab() {
    let scratch = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    let editor = EditorTab(title: "b.txt", path: "/x", content: "x")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [scratch, editor], hasProject: false, visibleDocumentWindows: 1
    ))
}

@Test("⌘N: einzelner Tab mit Inhalt → Fenster-Kommando")
func newWindowCommand_opensWindowForUsedTab() {
    let editor = EditorTab(title: "a.txt", path: "/x", content: "x")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [editor], hasProject: false, visibleDocumentWindows: 1
    ))
}

@Test("⌘N: Projekt geladen → Fenster-Kommando trotz leerem Tab")
func newWindowCommand_opensWindowWithProject() {
    let scratch = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    #expect(!WelcomeLogic.newWindowCommandOpensTab(
        tabs: [scratch], hasProject: true, visibleDocumentWindows: 1
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
