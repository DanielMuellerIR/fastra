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
    let rawPath: Data
    let originalPath: String?
    let rawOriginalPath: Data?
    let status: String
    let additions: Int?
    let deletions: Int?

    init(path: String, originalPath: String? = nil, status: String,
         additions: Int?, deletions: Int?) {
        self.path = path
        self.rawPath = Data(path.utf8)
        self.originalPath = originalPath
        self.rawOriginalPath = originalPath.map { Data($0.utf8) }
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    init(rawPath: Data, rawOriginalPath: Data? = nil, status: String,
         additions: Int?, deletions: Int?) {
        self.rawPath = rawPath
        self.path = String(decoding: rawPath, as: UTF8.self)
        self.rawOriginalPath = rawOriginalPath
        self.originalPath = rawOriginalPath.map { String(decoding: $0, as: UTF8.self) }
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    var id: Data { rawPath }
    /// `Process.arguments` kann keine ungültigen UTF-8-Bytes transportieren.
    /// Der Pfad bleibt lesbar, die zugehörige Aktion wird aber ehrlich gesperrt.
    var actionPath: String? { String(data: rawPath, encoding: .utf8) }
    var isPathActionable: Bool { actionPath != nil }
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
    /// Ausschließlich aus der exakten OID von `git status`, nie aus einem
    /// Decoration-Text wie `HEAD -> main` abgeleitet.
    let isHEAD: Bool

    var id: String { commit.hash }
}

/// Ergebnis des Layouts: die Zeilen plus die Gesamt-Spaltenzahl (für die Zellbreite).
struct GraphLayout: Equatable {
    let rows: [GraphRow]
    let laneCount: Int       // Anzahl benötigter Spalten (≥ 1)
}

/// Pure Präsentation des exakt ermittelten HEAD-Zustands. Branch-Decorations
/// sind kein Input; der Branchname stammt aus demselben Status-Snapshot wie die
/// HEAD-OID.
struct GitHeadPresentation: Equatable {
    let label: String
    let tooltip: String
    let isDetached: Bool

    static func make(row: GraphRow, branch: String?) -> GitHeadPresentation? {
        guard row.isHEAD else { return nil }
        if let branch, !branch.isEmpty {
            return GitHeadPresentation(
                label: L10n.format("HEAD · %@", branch),
                tooltip: L10n.format("HEAD bezeichnet den aktuell ausgecheckten Commit. Der lokale Branch ist %@.", branch),
                isDetached: false
            )
        }
        return GitHeadPresentation(
            label: L10n.format("HEAD · %@ · detached", row.commit.shortHash),
            tooltip: L10n.format("HEAD bezeichnet den aktuell ausgecheckten Commit. Detached HEAD: Kein lokaler Branch ist ausgecheckt; HEAD zeigt direkt auf %@.", row.commit.shortHash),
            isDetached: true
        )
    }
}

enum GitGraphAccessibility {
    static func commitHint(isHEAD: Bool, hasFiles: Bool, isExpanded: Bool) -> String {
        var parts: [String] = []
        if isHEAD { parts.append(L10n.string("HEAD bezeichnet den aktuell ausgecheckten Commit.")) }
        parts.append(L10n.string("Die Aktion „Commit-Diff öffnen“ zeigt den vollständigen Commit-Diff."))
        if hasFiles {
            parts.append(isExpanded
                         ? L10n.string("Die Dateiliste ist ausgeklappt und kann eingeklappt werden.")
                         : L10n.string("Die Dateiliste ist eingeklappt und kann ausgeklappt werden."))
        }
        return parts.joined(separator: " ")
    }

    static func fileHint(actionable: Bool) -> String {
        actionable
            ? L10n.string("Öffnet den Vorher-Nachher-Diff dieser Datei.")
            : L10n.string("Dieser Dateipfad enthält ungültiges UTF-8 und kann nicht sicher an Git übergeben werden.")
    }
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
    private static let recordSep: UInt8 = 0x1e
    private static let unitSep: UInt8 = 0x1f

    /// Argumente für `git log`. `--all` zeigt alle Branches (echter Graph),
    /// `--topo-order` hält Verzweigungen zusammenhängend (kein Datums-Zickzack),
    /// die Obergrenze deckelt sehr große Historien.
    static let arguments: [String] = [
        "log", "--all", "--topo-order", "-2000",
        "--pretty=format:%x1e%H%x1f%P%x1f%an%x1f%as%x1f%at%x1f%D%x1f%s%x00",
        // Merge-Dateien relativ zum ersten Eltern-Commit zeigen. Ohne diese
        // Option lässt git bei Merge-Commits Raw-/Numstat-Daten komplett weg.
        "-z", "--raw", "--numstat", "--find-renames", "--diff-merges=first-parent",
    ]

    /// Parst ausschließlich das dokumentierte NUL-Protokoll von `git log -z`.
    /// Pfade werden erst nach der strukturellen Trennung dekodiert; Tabs und
    /// Zeilenumbrüche im Dateinamen bleiben deshalb echte Pfadbytes.
    static func parse(_ raw: Data) -> [GitCommit] {
        struct RawFile {
            let path: Data
            let originalPath: Data?
            let status: String
        }
        struct Builder {
            let fields: [Data]
            var files: [RawFile] = []
            var counts: [Data: (Int?, Int?)] = [:]
        }

        let tokens = [UInt8](raw).split(separator: 0, omittingEmptySubsequences: false)
            .map { Data($0) }
        var commits: [GitCommit] = []
        var builder: Builder?
        var index = 0

        func decoded(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        func appendBuilder(_ value: Builder?) {
            guard let value, value.fields.count >= 7 else { return }
            let hash = decoded(value.fields[0])
            guard !hash.isEmpty else { return }
            let parents = decoded(value.fields[1]).split(separator: " ").map(String.init)
            let refs = decoded(value.fields[5]).components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let files = value.files.map { file in
                let count = value.counts[file.path]
                return GitCommitFile(rawPath: file.path, rawOriginalPath: file.originalPath,
                                     status: file.status, additions: count?.0,
                                     deletions: count?.1)
            }
            commits.append(GitCommit(hash: hash, parents: parents,
                                     author: decoded(value.fields[2]),
                                     date: decoded(value.fields[3]),
                                     timestamp: Int64(decoded(value.fields[4])) ?? 0,
                                     refs: refs, subject: decoded(value.fields[6]),
                                     files: files))
        }

        while index < tokens.count {
            var token = tokens[index]
            if token.first == recordSep {
                appendBuilder(builder)
                token.removeFirst()
                builder = Builder(fields: [UInt8](token).split(
                    separator: unitSep, omittingEmptySubsequences: false
                ).map { Data($0) })
                index += 1
                continue
            }
            guard builder != nil else { index += 1; continue }
            // Git setzt genau vor den ersten Raw-Header eines Commits ein LF.
            // Nur dieses strukturelle LF entfernen; ein Pfadfeld darf selbst
            // mit beliebig vielen Zeilenumbrüchen beginnen.
            if token.first == 0x0a, token.dropFirst().first == 0x3a { token.removeFirst() }
            if token.first == 0x3a, // ':' — Raw-Header, Pfade folgen als NUL-Felder
               let rawStatus = token.split(separator: 0x20).last,
               let statusByte = rawStatus.first {
                let status = String(UnicodeScalar(statusByte))
                let pathCount = statusByte == 0x52 || statusByte == 0x43 ? 2 : 1 // R/C
                guard index + pathCount < tokens.count else { index += 1; continue }
                let original = pathCount == 2 ? tokens[index + 1] : nil
                let path = tokens[index + pathCount]
                if !path.isEmpty {
                    builder?.files.append(RawFile(path: path, originalPath: original,
                                                  status: status))
                }
                index += pathCount + 1
                continue
            }
            if let parsed = parseNumstatToken(token, following: tokens, index: index) {
                builder?.counts[parsed.path] = (parsed.additions, parsed.deletions)
                index += parsed.consumed
                continue
            }
            index += 1
        }
        appendBuilder(builder)
        return commits
    }

    /// Numstat besitzt zwei fest definierte TAB-Felder für Zahlen; mit `-z`
    /// ist alles danach ein NUL-begrenzter Pfad. Bei Rename/Copy folgen alter
    /// und neuer Pfad als zwei weitere NUL-Felder.
    private static func parseNumstatToken(_ token: Data, following tokens: [Data], index: Int)
        -> (additions: Int?, deletions: Int?, path: Data, consumed: Int)? {
        guard let firstTab = token.firstIndex(of: 0x09),
              let secondTab = token[token.index(after: firstTab)...].firstIndex(of: 0x09)
        else { return nil }
        let additionsRaw = token[..<firstTab]
        let deletionsRaw = token[token.index(after: firstTab)..<secondTab]
        guard additionsRaw == Data("-".utf8) || Int(String(decoding: additionsRaw, as: UTF8.self)) != nil,
              deletionsRaw == Data("-".utf8) || Int(String(decoding: deletionsRaw, as: UTF8.self)) != nil
        else { return nil }
        let inlinePath = Data(token[token.index(after: secondTab)...])
        let path: Data
        let consumed: Int
        if inlinePath.isEmpty { // Rename/Copy: <counts>\0<old>\0<new>\0
            guard index + 2 < tokens.count else { return nil }
            path = tokens[index + 2]
            consumed = 3
        } else {
            path = inlinePath
            consumed = 1
        }
        return (Int(String(decoding: additionsRaw, as: UTF8.self)),
                Int(String(decoding: deletionsRaw, as: UTF8.self)), path, consumed)
    }

    /// Nur für kleine handgeschriebene Metadaten-Fixtures. Produktionsaufrufe
    /// verwenden immer `Data` und das NUL-Protokoll.
    static func parse(_ raw: String) -> [GitCommit] { parse(Data(raw.utf8)) }

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
    static func layout(_ commits: [GitCommit], headOID: String? = nil) -> GraphLayout {
        /// Eine offene Lane: erwarteter nächster Commit + stabile Farbe.
        struct Lane { let target: String; let colorIndex: Int }

        var lanes: [Lane?] = []
        // Farbe 0 (Blau) folgt der exakten HEAD-OID aus `git status`. Graph-
        // Decorations sind reine Anzeige und dürfen HEAD nicht mehr erraten.
        // Ohne Status (z.B. pure Layout-Nutzung) erhält nur die erste sichtbare
        // Lane die Grundfarbe; das ist ausdrücklich keine HEAD-Aussage.
        let primaryHash = headOID ?? commits.first?.hash
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
                        // Nebenast hat die Basis dann bereits vorgemerkt. Beide
                        // Lanes dürfen denselben Commit erwarten; erst in dessen
                        // Zeile laufen sie sichtbar am Knoten zusammen.
                        lanes[nodeColumn] = Lane(target: parent, colorIndex: nodeColor)
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
                                 colorIndex: nodeColor, lines: lines,
                                 isHEAD: headOID == commit.hash))
        }

        return GraphLayout(rows: rows, laneCount: max(1, maxColumn + 1))
    }
}
