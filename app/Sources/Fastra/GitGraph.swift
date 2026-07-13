import Foundation

// GitGraph.swift
//
// Reine, GUI-freie Kernlogik für den Git-Graph-Tab (ROADMAP „Projekt- & Git-Ausbau",
// Phase 3). Zwei Teile, beide ohne AppKit/SwiftUI → voll per Swift Testing prüfbar:
//   1. Ein robuster Parser für ein maschinenlesbares `git log`-Format.
//   2. Der klassische „Lane"-Zuweisungs-Algorithmus, der jedem Commit eine Spalte
//      gibt und die Verzweigungs-/Merge-Linien als Segmente beschreibt.
// Die View (`GitGraphView`) macht daraus nur noch Striche und Kreise — sie kennt
// die Farb-*Indizes*, nicht die Algorithmik.

// MARK: - Datenmodell

/// Ein einzelner Commit, so wie ihn `git log` liefert. Rein datenhaltend.
struct GitCommitFile: Equatable, Identifiable {
    let path: String
    let status: String
    let additions: Int?
    let deletions: Int?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
}

struct GitCommit: Equatable, Identifiable {
    let hash: String          // voller SHA-1
    let parents: [String]     // Eltern-Hashes; leer = Root, ≥2 = Merge
    let author: String        // Autorname
    let date: String          // Autor-Datum, ISO-kurz (YYYY-MM-DD)
    let timestamp: Int64      // Autor-Datum als Unix-Zeit für Tooltip/Relativzeit
    let refs: [String]        // Decorations: "HEAD -> main", "origin/main", "tag: v1.0"
    let subject: String       // erste Commit-Zeile
    let files: [GitCommitFile]

    var id: String { hash }

    /// Kurz-Hash für die Anzeige (VS-Code-Stil: 7 Zeichen).
    var shortHash: String { String(hash.prefix(7)) }

    var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }

    init(hash: String, parents: [String], author: String, date: String,
         timestamp: Int64 = 0, refs: [String], subject: String,
         files: [GitCommitFile] = []) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.timestamp = timestamp
        self.refs = refs
        self.subject = subject
        self.files = files
    }
}

/// Eine gezeichnete Linie innerhalb EINER Graph-Zeile. Die Zeile ist ein festes
/// Rechteck; `y` läuft von 0 (Oberkante) bis 1 (Unterkante), der Knoten sitzt bei
/// `y = 0.5`. Weil benachbarte Zeilen dieselbe Spaltenbreite nutzen, stoßen die
/// Segmente an den Zell-Kanten exakt zusammen → optisch durchgehende Linien.
struct GraphLine: Equatable {
    enum Kind: Equatable {
        case through    // unberührte Lane: senkrecht von Ober- zu Unterkante
        case incoming   // von oben (Spalte oben) herab zum Knoten (Mitte)
        case outgoing   // vom Knoten (Mitte) hinab zur Spalte an der Unterkante
        case joining    // Neben-Lane mündet zwischen zwei Commit-Zeilen ein
    }
    let fromColumn: Int   // Spalte am oberen Ende des Segments
    let toColumn: Int     // Spalte am unteren Ende des Segments
    let colorIndex: Int   // stabile Lane-Farbe (View mappt Index → Farbe)
    let kind: Kind
}

/// Eine fertige Graph-Zeile: der Commit, seine Spalte/Farbe und alle Linien, die
/// in seiner Zelle zu zeichnen sind.
struct GraphRow: Identifiable, Equatable {
    let commit: GitCommit
    let column: Int          // Spalte des Knoten-Kreises
    let colorIndex: Int      // Farbe des Knotens (= Farbe seiner Haupt-Lane)
    let lines: [GraphLine]

    var id: String { commit.hash }
}

/// Ergebnis des Layouts: die Zeilen plus die Gesamt-Spaltenzahl (für die Zellbreite).
struct GraphLayout: Equatable {
    let rows: [GraphRow]
    let laneCount: Int       // Anzahl benötigter Spalten (≥ 1)
}

// MARK: - Parser + Layout

enum GitGraph {

    // --- Format ---
    // Steuerzeichen als Trennzeichen, damit `|`/Kommas in Betreff/Refs nicht
    // stören: RS (0x1e) trennt Commits, US (0x1f) trennt Felder.
    //   %H = voller Hash · %P = Eltern (leer-getrennt) · %an = Autor
    //   %as = Autor-Datum (YYYY-MM-DD) · %at = Unix-Zeit
    //   %D = Decorations · %s = Betreff. Danach liefern `--raw --numstat`
    //   pro Datei Status sowie Einfügungen/Löschungen.
    private static let recordSep = "\u{1e}"
    private static let unitSep   = "\u{1f}"

    /// Argumente für `git log`. `--all` zeigt alle Branches (echter Graph),
    /// `--topo-order` hält Verzweigungen zusammenhängend (kein Datums-Zickzack),
    /// die Obergrenze deckelt sehr große Historien.
    static let arguments: [String] = [
        "log", "--all", "--topo-order", "-2000",
        "--pretty=format:\u{1e}%H\u{1f}%P\u{1f}%an\u{1f}%as\u{1f}%at\u{1f}%D\u{1f}%s",
        // Merge-Dateien relativ zum ersten Eltern-Commit zeigen. Ohne diese
        // Option lässt git bei Merge-Commits Raw-/Numstat-Daten komplett weg.
        "--raw", "--numstat", "--diff-merges=first-parent",
    ]

    /// Wandelt die rohe `git log`-Ausgabe in Commits. Robust gegen Sonderzeichen
    /// im Betreff (eigene Trennzeichen). Leere/kaputte Datensätze werden still
    /// übersprungen.
    static func parse(_ raw: String) -> [GitCommit] {
        raw.components(separatedBy: recordSep).compactMap { record -> GitCommit? in
            let fields = record.components(separatedBy: unitSep)
            guard fields.count >= 7 else { return nil }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { return nil }

            let parents = fields[1]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)

            // Decorations: git trennt sie mit ", ". Leerer String → keine Refs.
            let refs = fields[5]
                .components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // Das letzte Feld enthält zuerst den Betreff, danach die von
            // `--raw --numstat` erzeugten Dateizeilen.
            let payload = fields[6...].joined(separator: unitSep)
            let payloadLines = payload.components(separatedBy: .newlines)
            let subject = payloadLines.first ?? ""
            let detailLines = payloadLines.dropFirst().filter { !$0.isEmpty }

            // `--raw`: Status steht nach dem ersten Tab, bei Umbenennungen ist
            // der letzte Pfad der neue Zielpfad. Reihenfolge entspricht numstat.
            let statuses: [(status: String, path: String)] = detailLines.compactMap { line in
                guard line.hasPrefix(":") else { return nil }
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2,
                      let rawStatus = parts[0].split(separator: " ").last else { return nil }
                return (String(rawStatus.prefix(1)), parts.last ?? "")
            }
            let counts: [(additions: Int?, deletions: Int?, path: String)] = detailLines.compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3, !line.hasPrefix(":"),
                      Int(parts[0]) != nil || parts[0] == "-",
                      Int(parts[1]) != nil || parts[1] == "-" else { return nil }
                return (Int(parts[0]), Int(parts[1]), parts.last ?? "")
            }
            let fileCount = max(statuses.count, counts.count)
            let files = (0..<fileCount).map { index -> GitCommitFile in
                let status: (status: String, path: String) = index < statuses.count
                    ? statuses[index] : (status: "M", path: "")
                let count: (additions: Int?, deletions: Int?, path: String) = index < counts.count
                    ? counts[index] : (additions: nil, deletions: nil, path: "")
                return GitCommitFile(
                    path: status.path.isEmpty ? count.path : status.path,
                    status: status.status,
                    additions: count.additions,
                    deletions: count.deletions
                )
            }

            return GitCommit(
                hash: hash,
                parents: parents,
                author: fields[2],
                date: fields[3],
                timestamp: Int64(fields[4]) ?? 0,
                refs: refs,
                subject: subject,
                files: files
            )
        }
    }

    /// Weist jedem Commit eine Spalte zu und beschreibt die Verzweigungslinien.
    ///
    /// Verfahren (der Standard-Algorithmus, wie ihn gitk/VS Code nutzen):
    /// Wir führen eine Liste offener „Lanes". Jede Lane merkt sich, WELCHER Commit
    /// als Nächstes (weiter unten) in ihr erwartet wird, plus eine feste Farbe.
    /// Für jeden Commit von oben nach unten:
    ///   • Alle Lanes, die genau DIESEN Commit erwarten, laufen hier zusammen
    ///     („incoming"-Linien). Die linkeste wird zur Knotenspalte.
    ///   • Danach zeigt die Haupt-Lane auf den ersten Eltern-Commit; jeder weitere
    ///     Eltern-Commit (Merge) bekommt eine eigene Lane oder trifft eine bereits
    ///     offene („outgoing"-Linien).
    ///   • Alle übrigen offenen Lanes laufen senkrecht durch die Zeile („through").
    /// Spalten bleiben stabil (kein Verdichten) — nur so fluchten die Zell-Kanten.
    static func layout(_ commits: [GitCommit]) -> GraphLayout {
        /// Eine offene Lane: erwarteter nächster Commit + stabile Farbe.
        struct Lane { let target: String; let colorIndex: Int }

        var lanes: [Lane?] = []
        // Farbe 0 (Blau) ist exklusiv für den ausgecheckten Branch reserviert.
        // `git log --all` kann einen neueren fremden Branch vor HEAD liefern;
        // ohne Reservierung bekam dieser Blau und die eigentliche main-Linie
        // darunter Orange. VS Codium hält dagegen die aktuelle Branch-Linie
        // blau, unabhängig von der Sortierung der übrigen Branch-Tips.
        let primaryHash = commits.first(where: { commit in
            commit.refs.contains { $0.hasPrefix("HEAD -> ") }
        })?.hash ?? commits.first?.hash
        var colorCounter = 1
        var rows: [GraphRow] = []
        var maxColumn = 0

        // Erste freie (nil) Spalte; hängt bei Bedarf eine neue an.
        func firstFreeColumn() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }
        func nextColor() -> Int { defer { colorCounter += 1 }; return colorCounter }

        for commit in commits {
            // 1. Welche Lanes erwarten diesen Commit? (Kinder von oben.)
            let consumed = lanes.indices.filter { lanes[$0]?.target == commit.hash }

            // 2. Knotenspalte + Knotenfarbe bestimmen.
            let nodeColumn: Int
            let nodeColor: Int
            if commit.hash == primaryHash {
                // Trifft ein neuerer Nebenast direkt auf HEAD, endet seine
                // Farbe am HEAD-Knoten; die First-Parent-Linie läuft ab hier
                // in reserviertem Blau weiter.
                nodeColumn = consumed.first ?? firstFreeColumn()
                nodeColor = 0
            } else if let first = consumed.first {
                nodeColumn = first
                nodeColor = lanes[first]!.colorIndex
            } else {
                // Kein Kind erwartet ihn → neuer Branch-Tip in einer freien Spalte.
                nodeColumn = firstFreeColumn()
                nodeColor = nextColor()
            }

            // 3. Linien-Schnappschuss VOR dem Umbelegen der Lanes aufnehmen.
            var lines: [GraphLine] = []
            for i in lanes.indices {
                guard let lane = lanes[i] else { continue }
                if consumed.contains(i) {
                    // Zusammenlaufende Lane → von oben zum Knoten.
                    lines.append(GraphLine(fromColumn: i, toColumn: nodeColumn,
                                           colorIndex: lane.colorIndex, kind: .incoming))
                } else {
                    // Unbeteiligte Lane → senkrecht durch.
                    lines.append(GraphLine(fromColumn: i, toColumn: i,
                                           colorIndex: lane.colorIndex, kind: .through))
                }
            }

            // 4. Zusammengelaufene Lanes freigeben (Parents belegen gleich neu).
            for i in consumed { lanes[i] = nil }

            // 5. Eltern-Commits auf Lanes verteilen. Reihenfolge pro Elternteil:
            //    (a) ist der Eltern-Commit schon als Lane offen? → dort einmünden
            //        (Diamond/Merge — keine parallele Doppel-Lane erzeugen).
            //    (b) sonst erbt der erste „neue" Elternteil die Knotenspalte+Farbe
            //        (hält lineare Historie senkrecht in derselben Spalte).
            //    (c) jeder weitere neue Elternteil bekommt eine eigene Lane+Farbe.
            var mainLaneClaimed = false
            for (parentIndex, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0?.target == parent }) {
                    if parentIndex == 0, nodeColor == 0, existing != nodeColumn {
                        // Die blaue HEAD-Lane darf am gemeinsamen Vorfahren nicht
                        // von einer früher abgearbeiteten Neben-Lane übernommen
                        // werden. Das passiert bei Topo-Reihenfolgen wie
                        // Merge → Nebenast → Hauptast → gemeinsame Basis: Der
                        // Nebenast hat die Basis dann bereits vorgemerkt. Wir
                        // legen die Basis auf die Hauptspalte um und lassen die
                        // Nebenfarbe zwischen dieser und der nächsten Zeile
                        // einmünden – genau wie VS Codium.
                        let joiningColor = lanes[existing]!.colorIndex
                        lanes[existing] = nil
                        lanes[nodeColumn] = Lane(target: parent, colorIndex: nodeColor)
                        lines.append(GraphLine(fromColumn: existing, toColumn: nodeColumn,
                                               colorIndex: joiningColor, kind: .joining))
                        lines.append(GraphLine(fromColumn: nodeColumn, toColumn: nodeColumn,
                                               colorIndex: nodeColor, kind: .outgoing))
                        mainLaneClaimed = true
                    } else {
                        lines.append(GraphLine(fromColumn: nodeColumn, toColumn: existing,
                                               colorIndex: lanes[existing]!.colorIndex, kind: .outgoing))
                    }
                } else if !mainLaneClaimed {
                    lanes[nodeColumn] = Lane(target: parent, colorIndex: nodeColor)
                    lines.append(GraphLine(fromColumn: nodeColumn, toColumn: nodeColumn,
                                           colorIndex: nodeColor, kind: .outgoing))
                    mainLaneClaimed = true
                } else {
                    let col = firstFreeColumn()
                    let color = nextColor()
                    lanes[col] = Lane(target: parent, colorIndex: color)
                    lines.append(GraphLine(fromColumn: nodeColumn, toColumn: col,
                                           colorIndex: color, kind: .outgoing))
                }
            }
            // Kein Elternteil (Root): Knotenspalte bleibt nil → Lane endet hier.

            // Breitenbedarf mitschreiben (höchste je berührte Spalte).
            let touched = lines.flatMap { [$0.fromColumn, $0.toColumn] } + [nodeColumn]
            maxColumn = max(maxColumn, touched.max() ?? 0)

            rows.append(GraphRow(commit: commit, column: nodeColumn,
                                 colorIndex: nodeColor, lines: lines))
        }

        return GraphLayout(rows: rows, laneCount: max(1, maxColumn + 1))
    }
}
