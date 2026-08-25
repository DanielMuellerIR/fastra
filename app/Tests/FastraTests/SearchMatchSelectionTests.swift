// SearchMatchSelectionTests.swift
//
// Direkte Tests der aus dem SwiftUI-Suchdialog extrahierten Zustandsmaschine.
// Die Fixtures liefern echte BufferSearch-Treffer; keine Fenster oder Workspaces
// müssen dafür erzeugt werden.

import Foundation
import Testing
@testable import Fastra

private func selectionTestMatches() -> [BufferSearch.Match] {
    BufferSearch.find(
        in: "A B C",
        options: SearchOptions(find: "[ABC]", replace: "", isRegex: true)
    ).matches
}

private func selectionTargets(tabIDs: [UUID?] = [nil, nil, nil],
                              urls: [URL?] = [nil, nil, nil]) -> [Workspace.NavMatch] {
    let matches = selectionTestMatches()
    return matches.enumerated().map { index, match in
        Workspace.NavMatch(
            id: match.id,
            url: urls[index],
            tabID: tabIDs[index],
            match: match
        )
    }
}

@Test("Trefferklick wechselt Auswahl und liefert genau das aktuelle Ziel")
func searchMatchSelectionChangesOnClick() {
    let targets = selectionTargets()
    let transition = SearchMatchSelection.transition(
        activeIndex: 0,
        matches: targets,
        action: .select(matchID: targets[2].id)
    )

    #expect(transition.state == .selected(index: 2, matchID: targets[2].id))
    #expect(transition.output == .activate(targets[2]))
    #expect(SearchMatchSelection.target(for: transition.state, in: targets) == targets[2])
}

@Test("Vor/Zurück respektiert Wrap-around und feste Listenränder")
func searchMatchSelectionMovesWithExistingSemantics() {
    let targets = selectionTargets()

    let wrapped = SearchMatchSelection.transition(
        activeIndex: 0, matches: targets,
        action: .move(.previous, wrapAround: true)
    )
    #expect(wrapped.state == .selected(index: 2, matchID: targets[2].id))

    let clamped = SearchMatchSelection.transition(
        activeIndex: 2, matches: targets,
        action: .move(.next, wrapAround: false)
    )
    #expect(clamped.state == .selected(index: 2, matchID: targets[2].id))
    #expect(clamped.output == .activate(targets[2]))
}

@Test("Vor/Zurück rechnet nach einer Listenverkürzung vom geklemmten Treffer")
func searchMatchSelectionMovesFromReconciledIndex() {
    let targets = selectionTargets()

    let previous = SearchMatchSelection.transition(
        activeIndex: 7, matches: targets,
        action: .move(.previous, wrapAround: false)
    )
    #expect(previous.state == .selected(index: 1, matchID: targets[1].id))
    #expect(previous.output == .activate(targets[1]))

    let wrappedPrevious = SearchMatchSelection.transition(
        activeIndex: -4, matches: targets,
        action: .move(.previous, wrapAround: true)
    )
    #expect(wrappedPrevious.state == .selected(index: 2, matchID: targets[2].id))
    #expect(wrappedPrevious.output == .activate(targets[2]))

    let wrappedAfterMaximum = SearchMatchSelection.transition(
        activeIndex: .max, matches: targets,
        action: .move(.next, wrapAround: true)
    )
    #expect(wrappedAfterMaximum.state == .selected(index: 0, matchID: targets[0].id))
    #expect(wrappedAfterMaximum.output == .activate(targets[0]))
}

@Test("Veralteter Treffer erzeugt aus einer ersetzten Liste keinen Sprung")
func staleSearchMatchDoesNotActivateReplacement() {
    let oldTargets = selectionTargets()
    let replacement = Array(selectionTargets().prefix(1))

    let transition = SearchMatchSelection.transition(
        activeIndex: 2,
        matches: replacement,
        action: .select(matchID: oldTargets[2].id)
    )

    #expect(transition.state == .selected(index: 0, matchID: replacement[0].id))
    #expect(transition.output == .none)
}

@Test("Leere und ersetzte Ergebnislisten ergeben einen eindeutigen Detailzustand")
func emptyAndReplacedSearchResultsReconcileSelection() {
    let empty = SearchMatchSelection.transition(
        activeIndex: 7, matches: [], action: .reconcile
    )
    #expect(empty.state == .empty)
    #expect(empty.output == .none)

    let replacement = Array(selectionTargets().prefix(1))
    let reconciled = SearchMatchSelection.transition(
        activeIndex: 7, matches: replacement, action: .reconcile
    )
    #expect(reconciled.state == .selected(index: 0, matchID: replacement[0].id))
    #expect(SearchMatchSelection.target(for: reconciled.state, in: replacement)
            == replacement[0])
}

@Test("Erster Treffer und leere Aktionen liefern vollständige Zustände")
func firstAndEmptySearchMatchActionsAreExplicit() {
    let targets = selectionTargets()
    let first = SearchMatchSelection.transition(
        activeIndex: 2, matches: targets, action: .first
    )
    #expect(first.state == .selected(index: 0, matchID: targets[0].id))
    #expect(first.output == .activate(targets[0]))

    for action in [
        SearchMatchSelection.Action.select(matchID: UUID()),
        .move(.next, wrapAround: true),
        .first,
    ] {
        let empty = SearchMatchSelection.transition(
            activeIndex: 7, matches: [], action: action
        )
        #expect(empty.state == .empty)
        #expect(empty.output == .none)
    }
}

@Test("Auswahlzustand akzeptiert am gleichen Index keinen Ersatztreffer")
func selectionStateRejectsReplacementAtSameIndex() {
    let oldTargets = selectionTargets()
    let replacement = selectionTargets()
    let oldState = SearchMatchSelection.transition(
        activeIndex: 1, matches: oldTargets, action: .reconcile
    ).state

    #expect(SearchMatchSelection.target(for: oldState, in: replacement) == nil)
}

@Test("Tabwechsel verwendet ausschließlich die Ziel-ID der aktuellen Geöffnet-Liste")
func tabSwitchUsesCurrentOpenSearchTarget() {
    let oldTabID = UUID()
    let currentTabID = UUID()
    let oldTargets = selectionTargets(tabIDs: [oldTabID, nil, nil])
    let currentTargets = selectionTargets(tabIDs: [currentTabID, nil, nil])

    let stale = SearchMatchSelection.transition(
        activeIndex: 0, matches: currentTargets,
        action: .select(matchID: oldTargets[0].id)
    )
    #expect(stale.output == .none)

    let current = SearchMatchSelection.transition(
        activeIndex: 0, matches: currentTargets,
        action: .select(matchID: currentTargets[0].id)
    )
    guard case .activate(let target) = current.output else {
        Issue.record("Aktueller Tab-Treffer lieferte kein Navigationsziel")
        return
    }
    #expect(target.tabID == currentTabID)
}

@Test("Projektwechsel verwendet ausschließlich die URL der aktuellen Projektliste")
func projectSwitchUsesCurrentFolderSearchTarget() {
    let oldURL = URL(fileURLWithPath: "/tmp/altes-projekt/treffer.txt")
    let currentURL = URL(fileURLWithPath: "/tmp/neues-projekt/treffer.txt")
    let oldTargets = selectionTargets(urls: [oldURL, nil, nil])
    let currentTargets = selectionTargets(urls: [currentURL, nil, nil])

    let stale = SearchMatchSelection.transition(
        activeIndex: 0, matches: currentTargets,
        action: .select(matchID: oldTargets[0].id)
    )
    #expect(stale.output == .none)

    let current = SearchMatchSelection.transition(
        activeIndex: 0, matches: currentTargets,
        action: .select(matchID: currentTargets[0].id)
    )
    guard case .activate(let target) = current.output else {
        Issue.record("Aktueller Projekt-Treffer lieferte kein Navigationsziel")
        return
    }
    #expect(target.url == currentURL)
}
