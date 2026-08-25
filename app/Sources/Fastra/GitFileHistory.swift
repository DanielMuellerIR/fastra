import Foundation

// GitFileHistory.swift
//
// Reine, GUI-freie Logik für die auf EINE Datei eingeschränkte Verlaufsansicht
// (Graph-Tab der Seitenleiste). Drei Teile, alle ohne AppKit/SwiftUI und
// deshalb voll per Swift Testing prüfbar:
//   1. Die `git log`-Argumente für genau eine Datei.
//   2. Der Weg vom angeklickten Dateipfad zum Pfad relativ zur Repo-Wurzel.
//   3. Ein bewusst einspuriges Layout für die gefilterte Commit-Liste.

/// Worauf die Verlaufsansicht gerade eingeschränkt ist. `nil` in der Ansicht
/// bedeutet: ganze Historie.
struct GitHistoryFile: Equatable {
    /// Pfad relativ zur Repository-Wurzel — genau in dieser Form versteht ihn
    /// `git log -- <pfad>`.
    let relativePath: String

    /// Nur der Dateiname. Die Kopfzeile der schmalen Seitenleiste zeigt ihn,
    /// den vollen Pfad trägt der Tooltip.
    var name: String { (relativePath as NSString).lastPathComponent }
}

/// Ladezustand der Dateihistorie. Ein Fehler wird als echter git-Text
/// weitergereicht statt stillschweigend zu einer leeren Liste zu werden.
enum GitFileHistoryState: Equatable {
    case idle
    case loading
    case failed(String)
}

enum GitFileHistory {
    /// Obergrenze der geladenen Commits. Eine Dateihistorie ist fast immer
    /// kurz; die Grenze schützt nur vor Ausreißern wie einer über Jahre
    /// gepflegten Sammeldatei.
    static let limit = 500

    /// Argumente für den Verlauf EINER Datei.
    ///
    /// Format und Diff-Optionen sind dieselben wie bei `GitGraph.arguments` —
    /// nur so liefert derselbe Parser dieselben `GitCommit`-Werte. Zwei
    /// Unterschiede sind beabsichtigt:
    /// - kein `--all`: Gefragt ist die Historie, die zum aktuellen Stand der
    ///   Datei führt, nicht jede Fassung in jedem Branch.
    /// - `--follow`: git verfolgt die Datei über Umbenennungen hinweg. Das
    ///   funktioniert nur mit genau EINEM Pfad, deshalb nimmt diese Funktion
    ///   auch nur einen entgegen.
    static func arguments(relativePath: String, limit: Int = limit) -> [String] {
        [
            // Der Pfad stammt aus dem Dateibaum und ist kein Git-Pathspec.
            // Ohne diese globale Option würden Dateinamen mit `*`, `?`, `[` oder
            // einem `:(...)`-Präfix als Muster beziehungsweise Pathspec-Magic
            // ausgewertet und könnten den Verlauf anderer Dateien liefern.
            "--literal-pathspecs", "log", "--topo-order", "-\(limit)",
            "--pretty=format:%x1e%H%x1f%P%x1f%an%x1f%as%x1f%at%x1f%D%x1f%s%x00",
            "-z", "--raw", "--numstat", "--find-renames",
            "--diff-merges=first-parent", "--follow",
            "--", relativePath,
        ]
    }

    /// Bereits geladene Zeilen bleiben während eines Refreshs sichtbar. Ist
    /// der Refresh dagegen fehlgeschlagen, muss die echte Git-Fehlermeldung an
    /// die Stelle der alten Liste treten; sonst sähe der Nutzer veraltete
    /// Commits und nur den generischen Fehlertext in der Kopfzeile.
    static func commitsForDisplay(
        _ commits: [GitCommit],
        state: GitFileHistoryState
    ) -> [GitCommit] {
        if case .failed = state { return [] }
        return commits
    }

    /// Entfernt Aufklappzustand nur, wenn eine erfolgreich geladene Liste ihn
    /// wirklich nicht mehr enthält. Bei einem Refresh-Fehler bleibt die letzte
    /// Liste intern erhalten und kann nach „Erneut versuchen“ wieder erscheinen.
    static func reconciledExpandedCommits(
        _ expanded: Set<String>,
        commits: [GitCommit],
        state: GitFileHistoryState
    ) -> Set<String> {
        if case .failed = state { return expanded }
        return expanded.intersection(commits.map(\.hash))
    }

    /// Pfad der Datei relativ zur Repository-Wurzel, oder `nil`, wenn sie gar
    /// nicht darin liegt.
    ///
    /// Beide Seiten werden zuvor symlink-aufgelöst. Liegt das Projekt über
    /// einen Verweis — auf macOS ist schon `/tmp` einer auf `/private/tmp` —,
    /// verglichen sich sonst zwei Schreibweisen desselben Ordners, und jede
    /// Datei gälte als außerhalb des Projekts.
    ///
    /// Bei der Datei wird nur ihr ORDNER aufgelöst, nicht sie selbst: Ist die
    /// Datei ein Verweis, versioniert git den Verweis und nicht sein Ziel —
    /// gefragt ist also der Verlauf des Verweises, den der Nutzer angeklickt
    /// hat.
    static func relativePath(of file: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let directory = file.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let filePath = directory.appendingPathComponent(file.lastPathComponent).path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        let relative = String(filePath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// Layout für die gefilterte Liste: eine einzige Spalte, senkrecht
    /// durchverbunden.
    ///
    /// Der Lane-Algorithmus aus `GitGraph.layout` ist hier ausdrücklich FALSCH.
    /// Er baut die Spalten aus den Eltern-Hashes — und genau die fehlen in
    /// einer gefilterten Historie fast immer, weil git die Commits ohne
    /// Änderung an dieser Datei weglässt. Jede Zeile gälte dann als neuer
    /// Branch-Tip in einer eigenen Spalte, und die auf nie kommende Eltern
    /// wartenden Lanes zögen sich als Striche durch den ganzen Rest der Liste.
    /// Die einspurige Kette sagt stattdessen genau das, was die Liste zeigt:
    /// diese Commits, in dieser Reihenfolge, haben die Datei geändert.
    static func layout(_ commits: [GitCommit], headOID: String? = nil) -> GraphLayout {
        var rows: [GraphRow] = []
        for (index, commit) in commits.enumerated() {
            var lines: [GraphLine] = []
            if index > 0 {
                // Von der Oberkante zum Knoten — die Verbindung zum Commit darüber.
                lines.append(GraphLine(fromColumn: 0, toColumn: 0,
                                       colorIndex: 0, kind: .incoming))
            }
            if index < commits.count - 1 {
                // Vom Knoten zur Unterkante — die Verbindung zum Commit darunter.
                lines.append(GraphLine(fromColumn: 0, toColumn: 0,
                                       colorIndex: 0, kind: .outgoing))
            }
            rows.append(GraphRow(commit: commit, column: 0, colorIndex: 0,
                                 lines: lines, isHEAD: headOID == commit.hash))
        }
        return GraphLayout(rows: rows, laneCount: 1)
    }
}
