// SearchDialogLogicTests.swift
//
// Regressionstests für pure Entscheidungslogik des Suchdialogs. Visuelle
// Geometrie (z. B. ob ein Toggle abgeschnitten wird) bleibt laut QA-Strategie
// ein echter GUI-Test; die Zuordnung Treffer → Dateiname lässt sich dagegen
// vollständig und schnell ohne Fenster absichern.

import Foundation
import Testing
@testable import Fastra

/// Erzeugt einen echten Suchtreffer für die Navigationsziel-Tests. Dadurch
/// hängen die Tests nicht von einem handgebauten Match mit erfundenen Ranges
/// ab, sondern verwenden denselben Datentyp wie der produktive SearchRunner.
private func dialogTestMatch() -> BufferSearch.Match {
    let result = BufferSearch.find(
        in: "TREFFER",
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    )
    return result.matches[0]
}

@Test("Detailkopf im Geöffnet-Scope nennt den Ziel-Tab statt des aktiven Tabs")
func detailLabelUsesOpenScopeTargetTab() {
    let targetID = UUID()
    let targetTab = EditorTab(id: targetID, title: "Ziel.txt", path: "—")
    let activeTab = EditorTab(title: "Gerade-aktiv.txt", path: "—")
    let match = dialogTestMatch()
    let target = Workspace.NavMatch(id: match.id, url: nil,
                                    tabID: targetID, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [activeTab, targetTab],
        fallback: activeTab.title
    ) == "Ziel.txt")
}

@Test("Detailkopf im Ordner-Scope nennt die Datei des Treffers")
func detailLabelUsesFolderTargetURL() {
    let match = dialogTestMatch()
    let url = URL(fileURLWithPath: "/tmp/Unterordner/fundstelle.txt")
    let target = Workspace.NavMatch(id: match.id, url: url, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [],
        fallback: "Aktiver Buffer"
    ) == "fundstelle.txt")
}

@Test("Detailkopf im Datei-Scope verwendet weiterhin den aktiven Tab")
func detailLabelFallsBackForBufferMatch() {
    let match = dialogTestMatch()
    let target = Workspace.NavMatch(id: match.id, url: nil, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [],
        fallback: "Aktiv.txt"
    ) == "Aktiv.txt")
}

@Test("Treffer-Zeilennummer ist eine rohe Zahl ohne missverständliches Z-Präfix")
func hitLineLabelHasNoPrefixOrThousandsSeparator() {
    #expect(FloatingSearchDialog.hitLineLabel(1) == "1")
    #expect(FloatingSearchDialog.hitLineLabel(12_345) == "12345")
}
