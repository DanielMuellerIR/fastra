import Foundation

/// Abschnitt der Änderungen-Ansicht, in dem eine Zeile steht. Eine Datei kann
/// gleichzeitig bereitgestellt UND offen geändert sein (Porcelain „MM") und
/// erscheint dann in beiden Abschnitten — erst Abschnitt + Pfad identifizieren
/// eine Zeile eindeutig.
enum GitChangeSection: Hashable {
    case staged
    case unstaged
}

/// Eindeutige Identität einer Zeile in der Änderungen-Liste. `rawPath` statt
/// `path`, damit auch Nicht-UTF8-Pfade kollisionsfrei unterscheidbar bleiben.
struct GitChangeRowID: Hashable {
    let section: GitChangeSection
    let rawPath: Data
}

/// Reine Mehrfachauswahl-Logik der Änderungen-Liste (Daniel-Wunsch 2026-07-30):
/// Klick wählt genau eine Zeile, Cmd-Klick schaltet einzelne Zeilen um,
/// Shift-Klick wählt den Bereich vom Anker bis zur geklickten Zeile — wie in
/// macOS-Listen üblich. Bewusst ohne UI-Abhängigkeit, damit `swift test` das
/// Verhalten direkt prüfen kann.
struct GitChangesSelection: Equatable {
    private(set) var selected: Set<GitChangeRowID> = []
    /// Ausgangspunkt für Shift-Bereiche: die zuletzt ohne Shift geklickte Zeile.
    private(set) var anchor: GitChangeRowID?

    var count: Int { selected.count }

    func isSelected(_ row: GitChangeRowID) -> Bool { selected.contains(row) }

    /// Einfacher Klick: Auswahl auf genau diese Zeile zusammenziehen.
    mutating func click(_ row: GitChangeRowID) {
        selected = [row]
        anchor = row
    }

    /// Cmd-Klick: Zeile einzeln hinzunehmen oder wieder abwählen. Der Anker
    /// wandert in beiden Fällen mit, wie in AppKit-Listen.
    mutating func commandClick(_ row: GitChangeRowID) {
        if selected.contains(row) {
            selected.remove(row)
        } else {
            selected.insert(row)
        }
        anchor = row
    }

    /// Shift-Klick: Bereich vom Anker bis zur Zeile wählen; er ERSETZT die
    /// bisherige Auswahl. Der Anker bleibt stehen, damit ein weiterer
    /// Shift-Klick den Bereich vom selben Ausgangspunkt neu aufspannt.
    /// `orderedRows` ist die sichtbare Reihenfolge beider Abschnitte; ohne
    /// (noch) gültigen Anker verhält sich der Klick wie ein einfacher Klick.
    mutating func shiftClick(_ row: GitChangeRowID, orderedRows: [GitChangeRowID]) {
        guard let anchor,
              let from = orderedRows.firstIndex(of: anchor),
              let to = orderedRows.firstIndex(of: row) else {
            click(row)
            return
        }
        selected = Set(orderedRows[min(from, to)...max(from, to)])
    }

    /// Nach einem Status-Refresh verschwundene Zeilen austragen (z.B. wurde
    /// eine Datei committet oder verworfen). Sonst wirkte eine spätere
    /// Sammel-Aktion auf unsichtbare Reste.
    mutating func prune(existing: [GitChangeRowID]) {
        let valid = Set(existing)
        selected.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = nil }
    }
}

/// Plant das Verwerfen einer Auswahl, bevor etwas passiert: teilt in
/// unversionierte Dateien (werden gelöscht — git kennt sie nicht) und
/// getrackte Pfade (ein gemeinsames `git checkout --`) auf. Rein funktional,
/// damit die Aufteilung ohne echtes Repo testbar ist.
struct GitDiscardPlan {
    /// Nur ungestagete, aktionsfähige Änderungen — alles andere fällt vorab raus.
    let changes: [GitChange]
    /// Repo-relative Pfade der unversionierten Dateien/Ordner (löschen).
    let untrackedPaths: [String]
    /// Repo-relative Pfade der getrackten Dateien (`git checkout --`).
    let trackedPaths: [String]

    init(changes: [GitChange]) {
        let actionable = changes.filter { $0.unstaged != nil && $0.isPathActionable }
        self.changes = actionable
        self.untrackedPaths = actionable
            .filter { $0.unstaged == .untracked }
            .compactMap(\.actionPath)
        self.trackedPaths = actionable
            .filter { $0.unstaged != .untracked }
            .compactMap(\.actionPath)
    }

    var isEmpty: Bool { changes.isEmpty }
    var totalCount: Int { changes.count }
}
