// WindowTabsMenuTests.swift
//
// Beschriftungslogik der Tab-Untermenüs im „Fenster"-Menü (Daniel-Wunsch
// 2026-09-01): pro Dokumentfenster ein Eintrag mit allen offenen Tabs. Der
// Eintragstitel selbst kommt fertig aus `MainWindowTitleMetadata` (dort ist
// der Willkommens-Zustand schon berücksichtigt); hier bleibt die reine
// Zeilen-Beschriftung prüfbar. Die Befüllung beim Öffnen deckt der
// tabflood-Fenster-Selbsttest ab.

import AppKit
import Foundation
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

@Suite("Fenster-Menü: Neuaufbau des Menüs")
@MainActor
struct WindowTabsMenuRebuildTests {
    @Test("Einträge und Trenner ziehen in ein neu aufgebautes Fenster-Menü um")
    func entriesMoveToRebuiltMenu() {
        // SwiftUI kann das App-Menü nach dem Start neu aufbauen; dann ist
        // `NSApp.windowsMenu` eine andere Instanz. Vor der Korrektur (Review
        // 2026-09-02) blieben die gecachten Einträge am alten Menü hängen.
        let suite = "fastra-tests-windowtabsmenu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: true)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: true)
        let menus = WindowsMenuTabs()

        let oldMenu = NSMenu(title: "Fenster")
        oldMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        menus.updateItem(for: windowA, workspace: workspace, title: "A", in: oldMenu)
        menus.updateItem(for: windowB, workspace: workspace, title: "B", in: oldMenu)
        #expect(oldMenu.items.map(\.title) == ["A", "B", "", "Minimieren"])

        let newMenu = NSMenu(title: "Fenster")
        newMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        menus.updateItem(for: windowA, workspace: workspace, title: "A2", in: newMenu)

        #expect(oldMenu.items.map(\.title) == ["Minimieren"],
                "Im alten Menü darf kein verwalteter Eintrag zurückbleiben")
        #expect(newMenu.items.count == 4)
        #expect(Set(newMenu.items.prefix(2).map(\.title)) == ["A2", "B"],
                "Beide Fenster-Einträge stehen wieder am Anfang des neuen Menüs")
        #expect(newMenu.items[2].isSeparatorItem)
        #expect(newMenu.items[3].title == "Minimieren")

        // Schließen entfernt aus dem NEUEN Menü, nicht aus dem alten.
        menus.removeItem(for: windowB)
        menus.removeItem(for: windowA)
        #expect(newMenu.items.map(\.title) == ["Minimieren"])
    }
}
