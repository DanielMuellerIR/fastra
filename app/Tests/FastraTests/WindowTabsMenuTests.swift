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
        #expect(newMenu.items.prefix(2).map(\.title) == ["A2", "B"],
                "Beide Fenster-Einträge stehen in der alten Reihenfolge am Anfang")
        #expect(newMenu.items[2].isSeparatorItem)
        #expect(newMenu.items[3].title == "Minimieren")

        // Schließen entfernt aus dem NEUEN Menü, nicht aus dem alten.
        menus.removeItem(for: windowB)
        menus.removeItem(for: windowA)
        #expect(newMenu.items.map(\.title) == ["Minimieren"])
    }

    /// Hilfsfenster für die Umzugstests — Größe und Stil sind egal.
    private static func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test("Der zentrale Abgleich zieht auch ohne Bridge-Update um")
    func synchronizeMovesEntriesWithoutBridgeUpdate() {
        // Review 2026-09-02: `adoptMenuIfChanged` lief nur im nächsten
        // `updateItem` der Bridge. Ersetzte SwiftUI das Menü danach, blieb
        // das Tab-Untermenü bis zu einem nicht garantierten Titel-Update weg.
        // Der `AppDelegate` ruft deshalb den Abgleich bei jeder Menüänderung
        // und App-Aktivierung; hier wird sein Kern direkt getrieben.
        let suite = "fastra-tests-windowtabsmenu-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let windows = (0..<3).map { _ in Self.makeWindow() }
        let menus = WindowsMenuTabs()

        let oldMenu = NSMenu(title: "Fenster")
        oldMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        for (index, window) in windows.enumerated() {
            menus.updateItem(for: window, workspace: workspace,
                             title: "Fenster \(index)", in: oldMenu)
        }

        let newMenu = NSMenu(title: "Fenster")
        newMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        menus.adoptMenuIfChanged(newMenu)

        #expect(oldMenu.items.map(\.title) == ["Minimieren"])
        #expect(newMenu.items.map(\.title)
                == ["Fenster 0", "Fenster 1", "Fenster 2", "", "Minimieren"],
                "Alle Einträge stehen in Anlage-Reihenfolge vor dem Trenner")
        #expect(newMenu.items[3].isSeparatorItem)

        // Ein zweiter Abgleich auf dasselbe Menü ist wirkungslos.
        menus.adoptMenuIfChanged(newMenu)
        #expect(newMenu.items.map(\.title)
                == ["Fenster 0", "Fenster 1", "Fenster 2", "", "Minimieren"])
    }

    @Test("Ein halb umgezogener Abschnitt endet in der ursprünglichen Reihenfolge")
    func partialMoveKeepsCreationOrder() {
        // Das Titel-Update EINES Fensters kann den Umzug schon angestoßen
        // haben, bevor der zentrale Abgleich läuft. Die restlichen Einträge
        // dürfen dann nicht vor den bereits umgezogenen landen.
        let suite = "fastra-tests-windowtabsmenu-partial-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let windows = (0..<3).map { _ in Self.makeWindow() }
        let menus = WindowsMenuTabs()

        let oldMenu = NSMenu(title: "Fenster")
        for (index, window) in windows.enumerated() {
            menus.updateItem(for: window, workspace: workspace,
                             title: "Fenster \(index)", in: oldMenu)
        }
        let newMenu = NSMenu(title: "Fenster")
        newMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        // Der Umzug nimmt beim ersten Kontakt gleich alle mit — auch wenn
        // nur das letzte Fenster ein Titel-Update bekam.
        menus.updateItem(for: windows[2], workspace: workspace,
                         title: "Fenster 2 neu", in: newMenu)
        #expect(newMenu.items.map(\.title)
                == ["Fenster 0", "Fenster 1", "Fenster 2 neu", "", "Minimieren"])

        // Schließen des mittleren Fensters hält die Reihenfolge der übrigen.
        menus.removeItem(for: windows[1])
        #expect(newMenu.items.map(\.title)
                == ["Fenster 0", "Fenster 2 neu", "", "Minimieren"])
        let thirdMenu = NSMenu(title: "Fenster")
        menus.adoptMenuIfChanged(thirdMenu)
        #expect(thirdMenu.items.map(\.title) == ["Fenster 0", "Fenster 2 neu", ""])
        #expect(newMenu.items.map(\.title) == ["Minimieren"])
    }

    @Test("Einträge eines freigegebenen Menüs ziehen trotzdem um")
    func entriesOfReleasedMenuAreReinserted() {
        // Gibt AppKit das alte Menü frei, hängen die Einträge nirgends mehr
        // (`menu == nil`). Vorher galt nur ein Eintrag mit FREMDEM Menü als
        // umzugspflichtig — diese Einträge wären für immer verschwunden.
        let suite = "fastra-tests-windowtabsmenu-released-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let windowA = Self.makeWindow()
        let windowB = Self.makeWindow()
        let menus = WindowsMenuTabs()

        var oldMenu: NSMenu? = NSMenu(title: "Fenster")
        menus.updateItem(for: windowA, workspace: workspace, title: "A", in: oldMenu!)
        menus.updateItem(for: windowB, workspace: workspace, title: "B", in: oldMenu!)
        oldMenu = nil

        let newMenu = NSMenu(title: "Fenster")
        newMenu.addItem(NSMenuItem(title: "Minimieren", action: nil, keyEquivalent: ""))
        menus.adoptMenuIfChanged(newMenu)
        #expect(newMenu.items.map(\.title) == ["A", "B", "", "Minimieren"])
    }

    @Test("Der Abgleich baut einen verlorenen Eintrag wieder auf")
    func synchronizationRebuildsMissingEntry() {
        // Live-Befund 2026-09-03: Das Dokumentfenster war sichtbar, sein
        // Eintrag im Fenster-Menü aber vollständig verschwunden. Ein reiner
        // Umzug vorhandener NSMenuItems kann diesen Zustand nicht reparieren.
        let suite = "fastra-tests-windowtabsmenu-rebuild-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let window = Self.makeWindow()
        window.title = "Dokument.txt"
        let menus = WindowsMenuTabs()
        let menu = NSMenu(title: "Fenster")

        menus.updateItem(for: window, workspace: workspace,
                         title: window.title, in: menu)
        menus.removeItem(for: window)
        #expect(menu.items.isEmpty)

        menus.synchronize([(window, workspace)], in: menu)

        #expect(menu.items.count == 2)
        #expect(menu.items[0].title == "Dokument.txt")
        #expect(menu.items[0].submenu != nil)
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test("Der Abgleich entfernt Einträge bereits ausgeblendeter Fenster")
    func synchronizationRemovesClosedWindowEntry() {
        let suite = "fastra-tests-windowtabsmenu-prune-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let visibleWindow = Self.makeWindow()
        visibleWindow.title = "Sichtbar.txt"
        let closedWindow = Self.makeWindow()
        closedWindow.title = "Geschlossen.txt"
        let menus = WindowsMenuTabs()
        let menu = NSMenu(title: "Fenster")

        menus.synchronize(
            [(visibleWindow, workspace), (closedWindow, workspace)],
            in: menu
        )
        menus.synchronize([(visibleWindow, workspace)], in: menu)

        #expect(menu.items.map(\.title) == ["Sichtbar.txt", ""])
        #expect(menu.items[1].isSeparatorItem)
    }
}
