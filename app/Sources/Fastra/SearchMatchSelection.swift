// SearchMatchSelection.swift
//
// Reine Zustandsmaschine für Treffer-Auswahl und Detailnavigation. Der
// Workspace bleibt Besitzer der Trefferliste und des aktiven Indexes: Diese
// Komponente erhält beides nur als momentanen Snapshot und speichert nichts.

import Foundation

enum SearchMatchSelection {
    /// Der aus aktuellem Index und aktueller Ergebnisliste abgeleitete Zustand.
    /// Die Trefferidentität verhindert, dass ein später ersetztes Ergebnis am
    /// gleichen Zahlenindex versehentlich als die alte Auswahl behandelt wird.
    enum State: Equatable {
        case empty
        case selected(index: Int, matchID: UUID)

        var index: Int {
            switch self {
            case .empty: return 0
            case .selected(let index, _): return index
            }
        }
    }

    enum Direction: Equatable {
        case previous
        case next

        fileprivate var offset: Int {
            self == .previous ? -1 : 1
        }
    }

    /// Eingaben aus Trefferklick, Chevron-/Tastaturnavigation oder einem
    /// normalen SwiftUI-Neuaufbau nach einer ersetzten Ergebnisliste.
    enum Action: Equatable {
        case reconcile
        case select(matchID: UUID)
        case move(Direction, wrapAround: Bool)
        case first
    }

    /// Nur diskrete Nutzeraktionen erzeugen ein Navigationsziel. `reconcile`
    /// passt ausschließlich den abgeleiteten Detailzustand an und löst weder
    /// Tab-/Dateiwechsel noch Editor-Sprünge aus.
    enum Output: Equatable {
        case none
        case activate(Workspace.NavMatch)
    }

    struct Transition: Equatable {
        let state: State
        let output: Output
    }

    static func transition(activeIndex: Int,
                           matches: [Workspace.NavMatch],
                           action: Action) -> Transition {
        let current = state(activeIndex: activeIndex, matches: matches)

        switch action {
        case .reconcile:
            return Transition(state: current, output: .none)

        case .select(let matchID):
            // Ein Klick kann nach einem asynchronen Suchlauf noch aus einer
            // inzwischen ersetzten List-Zeile eintreffen. Nur die AKTUELLE
            // Workspace-Liste darf dann Auswahl und Sprungziel bestimmen.
            guard let index = matches.firstIndex(where: { $0.id == matchID }) else {
                return Transition(state: current, output: .none)
            }
            return activation(at: index, matches: matches)

        case .first:
            guard !matches.isEmpty else {
                return Transition(state: .empty, output: .none)
            }
            return activation(at: 0, matches: matches)

        case .move(let direction, let wrapAround):
            guard !matches.isEmpty else {
                return Transition(state: .empty, output: .none)
            }
            var next = activeIndex + direction.offset
            if wrapAround {
                next = ((next % matches.count) + matches.count) % matches.count
            } else {
                next = max(0, min(matches.count - 1, next))
            }
            return activation(at: next, matches: matches)
        }
    }

    /// Löst den Zustand nur gegen genau die Liste auf, aus der er entstanden
    /// ist. Bei einer inzwischen ersetzten Liste liefert die Identitätsprüfung
    /// bewusst `nil`, statt am gleichen Index einen anderen Treffer zu zeigen.
    static func target(for state: State,
                       in matches: [Workspace.NavMatch]) -> Workspace.NavMatch? {
        guard case .selected(let index, let matchID) = state,
              matches.indices.contains(index),
              matches[index].id == matchID else { return nil }
        return matches[index]
    }

    private static func state(activeIndex: Int,
                              matches: [Workspace.NavMatch]) -> State {
        guard !matches.isEmpty else { return .empty }
        let index = max(0, min(matches.count - 1, activeIndex))
        return .selected(index: index, matchID: matches[index].id)
    }

    private static func activation(at index: Int,
                                   matches: [Workspace.NavMatch]) -> Transition {
        let target = matches[index]
        return Transition(
            state: .selected(index: index, matchID: target.id),
            output: .activate(target)
        )
    }
}
