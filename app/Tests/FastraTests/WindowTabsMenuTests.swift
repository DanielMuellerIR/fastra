// WindowTabsMenuTests.swift
//
// Beschriftungslogik der Tab-Untermenüs im „Fenster"-Menü (Daniel-Wunsch
// 2026-09-01): pro Dokumentfenster ein Eintrag mit allen offenen Tabs. Der
// Eintragstitel selbst kommt fertig aus `MainWindowTitleMetadata` (dort ist
// der Willkommens-Zustand schon berücksichtigt); hier bleibt die reine
// Zeilen-Beschriftung prüfbar. Die Befüllung beim Öffnen deckt der
// tabflood-Fenster-Selbsttest ab.

import Testing
@testable import Fastra

@Suite("Fenster-Menü: Tab-Untermenüs")
struct WindowTabsMenuTests {
    @Test("Ungesicherte Tabs tragen den Dirty-Punkt der Tab-Leiste")
    func rowTitleMarksUnsavedChanges() {
        #expect(WindowTabsMenuModel.rowTitle(
            title: "eins.txt", hasUnsavedChanges: false
        ) == "eins.txt")
        #expect(WindowTabsMenuModel.rowTitle(
            title: "eins.txt", hasUnsavedChanges: true
        ) == "eins.txt •")
    }
}
