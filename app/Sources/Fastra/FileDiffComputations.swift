// FileDiffComputations.swift
//
// Verwaltete Hintergrund-Berechnungen der Datei-Vergleichs-Tabs eines
// Fensters (Folgeauftrag „Diff tatsächlich abbrechen", 2026-09-05).
//
// Vorher lief jeder Vergleich als anonymer `Task.detached`, den niemand mehr
// erreichen konnte: Nach Tab- oder Fensterschluss und bei einer neuen
// Anfrage wurde nur das ERGEBNIS verworfen, die Rechnung lief zu Ende. Hier
// hält der Workspace je Tab genau einen Task und bricht ihn ab, sobald sein
// Ergebnis niemanden mehr interessiert. Der Kern (`FileDiff.compare` mit
// Abbruchquelle, `FileLoader.load` mit Abbruchquelle) reagiert darauf in
// jeder Phase.
//
// Gleiches Muster wie `GitPreviewLoads`: Der Workspace benutzt den Helfer
// nur auf dem Main-Thread; die Tasks selbst laufen im Hintergrund.

import Foundation

final class FileDiffComputations {
    /// Ein laufender Vergleich. Die `id` entwertet verspätete Rückmeldungen:
    /// Nur wer noch unter seiner eigenen `id` eingetragen ist, darf sein
    /// Ergebnis veröffentlichen und sich austragen.
    struct Ticket: Equatable {
        let id: UUID
        let tabID: UUID
    }

    private struct Computation {
        let ticket: Ticket
        var task: Task<Void, Never>?
    }
    private var computations: [UUID: Computation] = [:]

    /// Meldet eine neue Berechnung für den Tab an. Eine noch laufende
    /// Berechnung DESSELBEN Tabs wird dabei abgebrochen — die neue Anfrage
    /// soll nicht neben der alten um CPU und Speicher konkurrieren.
    func begin(tabID: UUID) -> Ticket {
        cancel(tabID: tabID)
        let ticket = Ticket(id: UUID(), tabID: tabID)
        computations[tabID] = Computation(ticket: ticket)
        return ticket
    }

    /// Hängt den gestarteten Task an sein Ticket. Ist das Ticket inzwischen
    /// entwertet (Tab schon wieder geschlossen), wird der Task sofort
    /// abgebrochen statt verwaist weiterzurechnen.
    func attach(_ task: Task<Void, Never>, to ticket: Ticket) {
        guard computations[ticket.tabID]?.ticket == ticket else {
            task.cancel()
            return
        }
        computations[ticket.tabID]?.task = task
    }

    /// `true`, solange das Ticket noch das aktuelle seines Tabs ist.
    func isCurrent(_ ticket: Ticket) -> Bool {
        computations[ticket.tabID]?.ticket == ticket
    }

    /// Trägt eine fertige Berechnung aus — nur, wenn sie noch die aktuelle
    /// ihres Tabs ist (eine neuere darf nicht mit ausgetragen werden).
    func finish(_ ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        computations.removeValue(forKey: ticket.tabID)
    }

    /// Anzahl der laufenden Berechnungen — für Tests, die belegen, dass die
    /// Verwaltung nach Abbrüchen nicht wächst.
    var activeCount: Int { computations.count }

    func cancel(tabID: UUID) {
        // Erst austragen, dann abbrechen: Selbst eine Rückmeldung, die
        // synchron auf den Abbruch folgt, findet ihr Ticket nicht mehr.
        guard let computation = computations.removeValue(forKey: tabID) else { return }
        computation.task?.cancel()
    }

    func cancelAll() {
        let cancelled = Array(computations.values)
        computations.removeAll()
        cancelled.forEach { $0.task?.cancel() }
    }

    /// Ein Fenster, das seinen Workspace freigibt, nimmt alle Vergleiche mit.
    /// `Task.cancel()` ist threadsicher und fasst kein UI an.
    deinit { cancelAll() }
}
