// TabComparisonSelectionTests.swift
//
// Regressionen der Zwei-Tab-Auswahl für „Dateien vergleichen…“:
// Der aktive Tab bleibt eindeutig, höchstens ein zweiter Tab ist markiert und
// nur normale Textdokumente dürfen den Vergleichsdialog vorbefüllen.

import Foundation
import Testing
@testable import Fastra

private func makeTabComparisonWorkspace() -> (
    workspace: Workspace,
    defaults: UserDefaults,
    suite: String
) {
    let suite = "fastra-tab-comparison-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let workspace = Workspace(defaults: defaults)
    return (workspace, defaults, suite)
}

private func documentTab(_ name: String) -> EditorTab {
    EditorTab(
        title: name,
        path: "/tmp/\(name)",
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        content: name
    )
}

@Test("Shift-Auswahl behält den aktiven Tab und ordnet das Paar wie die Tab-Leiste")
func comparisonSelectionKeepsCurrentTab() {
    let fixture = makeTabComparisonWorkspace()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
    let left = documentTab("links.txt")
    let current = documentTab("rechts.txt")
    fixture.workspace.tabs = [left, current]
    fixture.workspace.activeTabID = current.id

    fixture.workspace.selectTab(id: left.id, extendingComparison: true)

    #expect(fixture.workspace.activeTabID == current.id)
    #expect(fixture.workspace.comparisonTabID == left.id)
    #expect(fixture.workspace.selectedComparisonTabIDs == [left.id, current.id])
}

@Test("Shift-Auswahl ersetzt oder entfernt nur den zweiten Tab")
func comparisonSelectionReplacesAndTogglesCompanion() {
    let fixture = makeTabComparisonWorkspace()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
    let current = documentTab("aktuell.txt")
    let second = documentTab("zweiter.txt")
    let third = documentTab("dritter.txt")
    fixture.workspace.tabs = [current, second, third]
    fixture.workspace.activeTabID = current.id

    fixture.workspace.selectTab(id: second.id, extendingComparison: true)
    fixture.workspace.selectTab(id: third.id, extendingComparison: true)
    #expect(fixture.workspace.activeTabID == current.id)
    #expect(fixture.workspace.comparisonTabID == third.id)

    fixture.workspace.selectTab(id: third.id, extendingComparison: true)
    #expect(fixture.workspace.activeTabID == current.id)
    #expect(fixture.workspace.comparisonTabID == nil)

    fixture.workspace.selectTab(id: second.id, extendingComparison: true)
    fixture.workspace.selectTab(id: second.id)
    #expect(fixture.workspace.activeTabID == second.id)
    #expect(fixture.workspace.comparisonTabID == nil)
}

@Test("Nicht vergleichbarer Shift-Klick bleibt eine normale Einzelauswahl")
func ineligibleShiftSelectionFallsBackToSingleTab() {
    let fixture = makeTabComparisonWorkspace()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
    let current = documentTab("aktuell.txt")
    let welcome = EditorTab(
        title: "Willkommen",
        path: "—",
        isWelcome: true
    )
    fixture.workspace.tabs = [current, welcome]
    fixture.workspace.activeTabID = current.id

    fixture.workspace.selectTab(id: welcome.id, extendingComparison: true)

    #expect(fixture.workspace.activeTabID == welcome.id)
    #expect(fixture.workspace.comparisonTabID == nil)
    #expect(fixture.workspace.selectedComparisonTabIDs == nil)
}

@Test("Kontextaktion akzeptiert nur einen Tab des markierten Paars")
func selectedTabContextPrefillsCompareDialog() {
    let fixture = makeTabComparisonWorkspace()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
    let left = documentTab("links.txt")
    let current = documentTab("rechts.txt")
    let unrelated = documentTab("daneben.txt")
    fixture.workspace.tabs = [left, current, unrelated]
    fixture.workspace.activeTabID = current.id
    fixture.workspace.selectTab(id: left.id, extendingComparison: true)

    #expect(
        !fixture.workspace.presentComparisonForSelectedTabs(
            contextTabID: unrelated.id
        )
    )
    #expect(!fixture.workspace.showCompareFilesDialog)

    #expect(
        fixture.workspace.presentComparisonForSelectedTabs(
            contextTabID: current.id
        )
    )
    #expect(fixture.workspace.showCompareFilesDialog)
    #expect(
        fixture.workspace.compareDialogPrefillTabIDs == [left.id, current.id]
    )
}

@Test("Dialog-Vorbelegung nutzt explizites Paar, sonst den aktiven Tab links")
func compareDialogPrefillUsesPairOrActiveTab() {
    let left = documentTab("links.txt")
    let current = documentTab("rechts.txt")

    #expect(
        CompareDialogLogic.prefill(
            tabIDs: [left.id, current.id],
            activeTabID: current.id,
            tabs: [left, current]
        ) == CompareDialogPrefill(
            left: .tab(left.id),
            right: .tab(current.id)
        )
    )
    #expect(
        CompareDialogLogic.prefill(
            tabIDs: [],
            activeTabID: current.id,
            tabs: [left, current]
        ) == CompareDialogPrefill(
            left: .tab(current.id),
            right: .none
        )
    )
}

@Test("Schließen des Vergleichspartners räumt die Paarwahl auf")
func closingComparisonTabClearsSelection() {
    let fixture = makeTabComparisonWorkspace()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
    let current = documentTab("aktuell.txt")
    let second = documentTab("zweiter.txt")
    fixture.workspace.tabs = [current, second]
    fixture.workspace.activeTabID = current.id
    fixture.workspace.selectTab(id: second.id, extendingComparison: true)

    fixture.workspace.closeTab(id: second.id)

    #expect(fixture.workspace.tabs.map(\.id) == [current.id])
    #expect(fixture.workspace.activeTabID == current.id)
    #expect(fixture.workspace.comparisonTabID == nil)
}
