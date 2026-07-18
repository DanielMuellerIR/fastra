// FileDiff.swift
//
// UI-freier Zwei-Text-Zeilendiff (Etappe 1 Wunschpaket 2026-07c).
//
// Verallgemeinert die Zeilen-Ausrichtung aus `ReplacePreview.buildSideBySide`
// zu einer eigenständigen, voll testbaren Komponente: zwei Strings + Optionen
// hinein, ausgerichtete Zeilenpaare (unchanged/changed/removed/added) mit
// Intraline-Bereichen plus eine Differenzen-Liste (Blöcke) heraus.
// Funktioniert komplett OHNE Git — Basis ist Foundations
// `CollectionDifference` (Myers-Diff), wie schon in der Ersetzungs-Vorschau.
//
// Ehrliche Grenzen statt stiller Kappung: zu große oder zu unterschiedliche
// Eingaben liefern eine verständliche `FileDiffLimitation`, die die Ansicht
// sichtbar erklärt — es wird nie ein unvollständiger Diff als vollständig
// angezeigt (Produktinvariante).

import Foundation

/// Vergleichsoptionen — BBEdit-Teilmenge aus „Find Differences"
/// (User Manual 16.0.1, S. 130–134). Voreinstellung: nichts ignorieren.
struct FileDiffOptions: Hashable {
    /// Leerraum am Zeilenende ignorieren.
    var ignoreTrailingWhitespace = false
    /// ALLE Leerraum-Unterschiede ignorieren (schließt das Zeilenende ein).
    var ignoreAllWhitespace = false
    /// Leerzeilen ignorieren: nur-Leerzeilen-Unterschiede sind kein Unterschied.
    var ignoreBlankLines = false
    /// Groß-/Kleinschreibung ignorieren.
    var ignoreCase = false

    /// `true`, wenn keine Option aktiv ist (Voreinstellung).
    var isDefault: Bool { self == FileDiffOptions() }

    /// Vergleichs-Schlüssel einer Zeile nach den aktiven Optionen. Angezeigt
    /// wird immer die ORIGINALZEILE — normalisiert wird nur der Vergleich.
    func normalizedKey(for line: String) -> String {
        var key = line
        if ignoreAllWhitespace {
            key = String(key.filter { !$0.isWhitespace })
        } else if ignoreTrailingWhitespace {
            while let last = key.last, last.isWhitespace { key.removeLast() }
        }
        if ignoreCase { key = key.lowercased() }
        return key
    }
}

/// Rolle einer Vergleichsseite — für verständliche Fehlermeldungen
/// („linke Datei …") ohne den Dateinamen ins Modell zu ziehen.
enum FileDiffSideRole: Hashable {
    case left, right
}

/// Eine Vergleichsseite: entweder eine Datei auf der Platte (`url`) oder ein
/// bereits vorliegender Text (`text`, z. B. der ungespeicherte Editor-Inhalt
/// bei „Mit gespeicherter Fassung vergleichen"). Genau eines von beiden ist
/// gesetzt.
struct FileDiffSide: Hashable {
    /// Anzeigename im Kopf der Diff-Ansicht (Dateiname bzw. Tab-Titel).
    let name: String
    /// Voller Pfad für den Tooltip; `nil` bei reinem Editor-Inhalt.
    let path: String?
    /// Zu ladende Datei; `nil`, wenn `text` den Inhalt bereits mitbringt.
    let url: URL?
    /// Bereits vorliegender Inhalt; `nil`, wenn aus `url` geladen wird.
    let text: String?

    /// Seite aus einer Datei auf der Platte.
    static func file(_ url: URL) -> FileDiffSide {
        FileDiffSide(name: url.lastPathComponent, path: url.path, url: url, text: nil)
    }

    /// Seite aus einem bereits vorliegenden Text (ungespeicherter Editor).
    static func text(_ text: String, name: String, path: String? = nil) -> FileDiffSide {
        FileDiffSide(name: name, path: path, url: nil, text: text)
    }

    /// Gleiche LOGISCHE Quelle (Name, Pfad, Datei) — der Textinhalt zählt
    /// bewusst nicht: „Editor-Inhalt von X" bleibt dieselbe Quelle, auch
    /// wenn der Nutzer inzwischen weitergetippt hat. Basis der Tab-
    /// Wiederverwendung.
    func matchesLogically(_ other: FileDiffSide) -> Bool {
        name == other.name && path == other.path && url == other.url
            && (text == nil) == (other.text == nil)
    }
}

/// Auftrag für einen Datei-Vergleichs-Tab. `id` unterscheidet Neuberechnungen
/// desselben Vergleichs; inhaltlich gleiche Aufträge erkennt `matches(_:)`.
struct FileDiffRequest: Hashable, Identifiable {
    let id: UUID
    let left: FileDiffSide
    let right: FileDiffSide
    let options: FileDiffOptions

    init(left: FileDiffSide, right: FileDiffSide, options: FileDiffOptions) {
        self.id = UUID()
        self.left = left
        self.right = right
        self.options = options
    }

    /// Gleicher Vergleich (logische Quellen + Optionen), unabhängig von der
    /// `id` — Basis für „bestehenden Diff-Tab wiederverwenden statt stapeln".
    func matches(_ other: FileDiffRequest) -> Bool {
        left.matchesLogically(other.left) && right.matchesLogically(other.right)
            && options == other.options
    }
}

/// Fertig berechneter Inhalt eines Datei-Vergleichs-Tabs: entweder ein
/// Ergebnis oder eine erklärte Grenze (nie beides).
struct FileDiffDocument: Hashable {
    let result: FileDiff.Result?
    let limitation: FileDiffLimitation?

    static func success(_ result: FileDiff.Result) -> FileDiffDocument {
        FileDiffDocument(result: result, limitation: nil)
    }
    static func failure(_ limitation: FileDiffLimitation) -> FileDiffDocument {
        FileDiffDocument(result: nil, limitation: limitation)
    }
}

/// Verständliche Grenzen und Fehler des Datei-Vergleichs (Muster
/// `GitDiffLimitation`). Die Ansicht formuliert daraus Nutzersprache
/// inklusive der betroffenen Dateinamen. `Error`-Konformität erlaubt die
/// Verwendung in `Swift.Result` beim Laden der Vergleichsseiten.
enum FileDiffLimitation: Hashable, Error {
    /// Datei konnte nicht gelesen werden (fehlt, keine Rechte, Kodierung).
    case unreadable(side: FileDiffSideRole)
    /// Binärdatei — ein Zeilendiff wäre irreführend.
    case binary(side: FileDiffSideRole)
    /// Datei über der App-Grenze für vollständiges Laden (32 MiB).
    case tooLarge(side: FileDiffSideRole)
    /// Mehr Zeilen als der Vergleich verarbeitet.
    case tooManyLines(side: FileDiffSideRole, limit: Int)
    /// Nach Abzug gemeinsamer Anfangs-/Endzeilen bleibt mehr Unterschieds-
    /// Bereich als das Rechenbudget erlaubt (Myers-Diff ist im schlechtesten
    /// Fall quadratisch — wir lehnen ehrlich ab, statt minutenlang zu rechnen).
    case tooDifferent(limit: Int)
}

enum FileDiff {

    // MARK: - Ergebnistypen

    enum RowKind: Hashable {
        case unchanged, changed, removed, added
    }

    /// Eine ausgerichtete Anzeigezeile: links Vorher, rechts Nachher.
    /// `nil` auf einer Seite = dort existiert keine Gegenzeile.
    struct Row: Hashable, Identifiable {
        /// Fortlaufender Index — stabile ForEach-Identität UND Scroll-Ziel.
        let id: Int
        /// 1-basierte Zeilennummern (wie im Editor-Gutter).
        let beforeLine: Int?
        let afterLine: Int?
        let before: String?
        let after: String?
        let kind: RowKind
        /// Zeichen-Offsets des unterschiedlichen Mittelteils (nur `.changed`).
        let beforeHighlight: Range<Int>?
        let afterHighlight: Range<Int>?
        /// `true`, wenn die Zeile für die Intraline-Markierung zu lang war.
        let intralineWasLimited: Bool
        /// `true` = Leerzeile, die NUR wegen „Leerzeilen ignorieren" kein
        /// Unterschied ist. Sie bleibt sichtbar (keine stille Auslassung),
        /// zählt aber nicht als Differenz.
        let isIgnoredBlank: Bool
    }

    enum BlockKind: Hashable {
        /// Zeilen auf beiden Seiten verändert.
        case changed
        /// Zeilen existieren nur links (entfernt).
        case onlyLeft
        /// Zeilen existieren nur rechts (hinzugefügt).
        case onlyRight
    }

    /// Ein Eintrag der Differenzen-Liste: ein zusammenhängender Lauf
    /// veränderter Zeilen („Zeilen 12–14 geändert", „Zeile 30 nur links").
    struct Block: Hashable, Identifiable {
        let id: Int
        /// Erste/letzte Zeile des Blocks im `rows`-Array (Scroll-Ziel und
        /// Hervorhebung des gewählten Blocks).
        let firstRowID: Int
        let lastRowID: Int
        let kind: BlockKind
        /// Betroffene 1-basierte Zeilennummern je Seite (`nil` = Seite leer).
        let beforeLines: ClosedRange<Int>?
        let afterLines: ClosedRange<Int>?
    }

    struct Result: Hashable {
        let rows: [Row]
        let blocks: [Block]
        /// Zeilenanzahl beider Eingaben (für „N Zeilen identisch").
        let leftLineCount: Int
        let rightLineCount: Int
        /// Keine Blöcke = keine Unterschiede (unter den aktiven Optionen).
        var isIdentical: Bool { blocks.isEmpty }
    }

    /// Entweder ein vollständiges Ergebnis oder eine erklärte Grenze —
    /// nie ein stilles Teilergebnis.
    enum Outcome: Hashable {
        case result(Result)
        case limitation(FileDiffLimitation)
    }

    // MARK: - Grenzen

    /// Maximale Zeilenzahl je Seite. Schützt Speicher und Laufzeit; mehr
    /// Zeilen lehnt der Vergleich mit sichtbarer Erklärung ab.
    static let maximumLineCount = 200_000
    /// Budget für den eigentlichen Myers-Diff NACH Abzug gemeinsamer
    /// Anfangs- und Endzeilen (Summe beider Seiten). Der schlechteste Fall
    /// des Diffs wächst quadratisch — dieses Budget hält ihn im Sekunden-
    /// bereich. Typische Vergleiche (ähnliche Dateien) bleiben weit darunter.
    static let maximumDiffInputLines = 30_000

    // MARK: - Vergleich

    /// Vergleicht zwei Texte zeilenweise. Reine Funktion ohne UI — die
    /// Berechnung gehört auf einen Hintergrund-Task (kann bei großen Dateien
    /// spürbar dauern), das Ergebnis zurück auf den Main-Thread.
    static func compare(left: String, right: String,
                        options: FileDiffOptions = FileDiffOptions()) -> Outcome {
        // Wie `ReplacePreview.buildSideBySide`: `.newlines` trennt auch \r\n.
        // Ein Text mit End-Umbruch erhält dadurch eine letzte Leerzeile —
        // ein Unterschied im End-Umbruch bleibt so ehrlich sichtbar.
        let leftLines = left.components(separatedBy: .newlines)
        let rightLines = right.components(separatedBy: .newlines)
        guard leftLines.count <= maximumLineCount else {
            return .limitation(.tooManyLines(side: .left, limit: maximumLineCount))
        }
        guard rightLines.count <= maximumLineCount else {
            return .limitation(.tooManyLines(side: .right, limit: maximumLineCount))
        }

        // Vergleichs-Schlüssel je Zeile (Optionen); Anzeige bleibt Original.
        let leftKeys = leftLines.map { options.normalizedKey(for: $0) }
        let rightKeys = rightLines.map { options.normalizedKey(for: $0) }
        let leftBlank = leftLines.map(isBlank)
        let rightBlank = rightLines.map(isBlank)

        // Bei „Leerzeilen ignorieren" nehmen Leerzeilen NICHT am Diff teil —
        // sie werden später als ignorierte Zeilen wieder eingefügt.
        // `leftIndex[k]` = Original-Zeilenindex des k-ten Diff-Teilnehmers.
        var leftIndex: [Int] = []
        var rightIndex: [Int] = []
        if options.ignoreBlankLines {
            leftIndex = leftLines.indices.filter { !leftBlank[$0] }
            rightIndex = rightLines.indices.filter { !rightBlank[$0] }
        } else {
            leftIndex = Array(leftLines.indices)
            rightIndex = Array(rightLines.indices)
        }

        // Gleiche Schlüssel bekommen dieselbe Ganzzahl — der Myers-Diff
        // vergleicht dann Ganzzahlen statt Strings (deutlich schneller).
        var aliasByKey: [String: Int] = [:]
        func alias(_ key: String) -> Int {
            if let existing = aliasByKey[key] { return existing }
            let next = aliasByKey.count
            aliasByKey[key] = next
            return next
        }
        let leftAliases = leftIndex.map { alias(leftKeys[$0]) }
        let rightAliases = rightIndex.map { alias(rightKeys[$0]) }

        // Gemeinsamen Anfang und gemeinsames Ende abziehen — der teure Diff
        // läuft nur über den tatsächlich unterschiedlichen Mittelteil.
        var prefix = 0
        while prefix < min(leftAliases.count, rightAliases.count),
              leftAliases[prefix] == rightAliases[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(leftAliases.count, rightAliases.count) - prefix,
              leftAliases[leftAliases.count - 1 - suffix]
                == rightAliases[rightAliases.count - 1 - suffix] {
            suffix += 1
        }
        let leftMid = leftAliases[prefix..<(leftAliases.count - suffix)]
        let rightMid = rightAliases[prefix..<(rightAliases.count - suffix)]
        guard leftMid.count + rightMid.count <= maximumDiffInputLines else {
            return .limitation(.tooDifferent(limit: maximumDiffInputLines))
        }

        // Myers-Diff über den Mittelteil. Offsets sind relativ zum Mittelteil
        // → plus `prefix` ergibt den Index in der Diff-Teilnehmer-Folge,
        // `leftIndex`/`rightIndex` mappen zurück auf Original-Zeilen.
        var removedLeft = Set<Int>()    // Original-Zeilenindizes links
        var insertedRight = Set<Int>()  // Original-Zeilenindizes rechts
        let difference = Array(rightMid).difference(from: Array(leftMid))
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedLeft.insert(leftIndex[prefix + offset])
            case .insert(let offset, _, _):
                insertedRight.insert(rightIndex[prefix + offset])
            }
        }

        let rows = alignedRows(
            leftLines: leftLines, rightLines: rightLines,
            leftBlank: leftBlank, rightBlank: rightBlank,
            removedLeft: removedLeft, insertedRight: insertedRight,
            options: options
        )
        return .result(Result(rows: rows, blocks: blocks(for: rows),
                              leftLineCount: leftLines.count,
                              rightLineCount: rightLines.count))
    }

    /// Leerzeile = leer oder nur Leerraum (Basis der Option
    /// „Leerzeilen ignorieren").
    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0.isWhitespace }
    }

    // MARK: - Zeilen-Ausrichtung

    /// Baut aus den Diff-Mengen die ausgerichteten Anzeigezeilen. Gleicher
    /// Zwei-Zeiger-Lauf wie `ReplacePreview.buildSideBySide`, erweitert um
    /// ignorierte Leerzeilen und Intraline-Hervorhebung: aufeinanderfolgende
    /// entfernte und eingefügte Zeilen werden paarweise als `.changed`
    /// ausgerichtet, Überhänge bleiben `.removed`/`.added`.
    private static func alignedRows(
        leftLines: [String], rightLines: [String],
        leftBlank: [Bool], rightBlank: [Bool],
        removedLeft: Set<Int>, insertedRight: Set<Int>,
        options: FileDiffOptions
    ) -> [Row] {
        var rows: [Row] = []
        var i = 0
        var j = 0
        let leftCount = leftLines.count
        let rightCount = rightLines.count

        // Ignorierte Leerzeilen nehmen nicht am Diff teil; sie tauchen hier
        // als eigene, NICHT als Unterschied gezählte Zeilen wieder auf.
        func isIgnoredLeft(_ index: Int) -> Bool {
            options.ignoreBlankLines && leftBlank[index]
        }
        func isIgnoredRight(_ index: Int) -> Bool {
            options.ignoreBlankLines && rightBlank[index]
        }

        while i < leftCount || j < rightCount {
            // Ignorierte Leerzeilen zuerst — wo beide Seiten gerade eine
            // haben, teilen sie sich eine Anzeigezeile.
            if i < leftCount, isIgnoredLeft(i) {
                if j < rightCount, isIgnoredRight(j) {
                    rows.append(Row(id: rows.count, beforeLine: i + 1, afterLine: j + 1,
                                    before: leftLines[i], after: rightLines[j],
                                    kind: .unchanged, beforeHighlight: nil,
                                    afterHighlight: nil, intralineWasLimited: false,
                                    isIgnoredBlank: true))
                    i += 1; j += 1
                } else {
                    rows.append(Row(id: rows.count, beforeLine: i + 1, afterLine: nil,
                                    before: leftLines[i], after: nil,
                                    kind: .unchanged, beforeHighlight: nil,
                                    afterHighlight: nil, intralineWasLimited: false,
                                    isIgnoredBlank: true))
                    i += 1
                }
                continue
            }
            if j < rightCount, isIgnoredRight(j) {
                rows.append(Row(id: rows.count, beforeLine: nil, afterLine: j + 1,
                                before: nil, after: rightLines[j],
                                kind: .unchanged, beforeHighlight: nil,
                                afterHighlight: nil, intralineWasLimited: false,
                                isIgnoredBlank: true))
                j += 1
                continue
            }

            // Zusammenhängende Läufe entfernter (links) und eingefügter
            // (rechts) Zeilen einsammeln. Ignorierte Leerzeilen stehen nie
            // in den Diff-Mengen — sie beenden einen Lauf automatisch.
            var removedRun: [Int] = []
            while i + removedRun.count < leftCount,
                  removedLeft.contains(i + removedRun.count) {
                removedRun.append(i + removedRun.count)
            }
            var insertedRun: [Int] = []
            while j + insertedRun.count < rightCount,
                  insertedRight.contains(j + insertedRun.count) {
                insertedRun.append(j + insertedRun.count)
            }

            if removedRun.isEmpty, insertedRun.isEmpty {
                // Beide Seiten stehen auf einer gematchten Zeile → Paar.
                // (Der Diff matcht in Reihenfolge, daher sind hier immer
                // beide Indizes im Bereich.)
                guard i < leftCount, j < rightCount else { break }
                rows.append(Row(id: rows.count, beforeLine: i + 1, afterLine: j + 1,
                                before: leftLines[i], after: rightLines[j],
                                kind: .unchanged, beforeHighlight: nil,
                                afterHighlight: nil, intralineWasLimited: false,
                                isIgnoredBlank: false))
                i += 1; j += 1
                continue
            }

            // Entfernt+eingefügt paarweise als „geändert" ausrichten;
            // Überhänge bleiben einseitig.
            let pairCount = min(removedRun.count, insertedRun.count)
            for k in 0..<pairCount {
                let li = removedRun[k]
                let rj = insertedRun[k]
                let highlights = GitDiffParser.intraline(leftLines[li], rightLines[rj])
                rows.append(Row(id: rows.count, beforeLine: li + 1, afterLine: rj + 1,
                                before: leftLines[li], after: rightLines[rj],
                                kind: .changed,
                                beforeHighlight: highlights.before,
                                afterHighlight: highlights.after,
                                intralineWasLimited: highlights.wasLimited,
                                isIgnoredBlank: false))
            }
            for k in pairCount..<removedRun.count {
                rows.append(Row(id: rows.count, beforeLine: removedRun[k] + 1,
                                afterLine: nil, before: leftLines[removedRun[k]],
                                after: nil, kind: .removed, beforeHighlight: nil,
                                afterHighlight: nil, intralineWasLimited: false,
                                isIgnoredBlank: false))
            }
            for k in pairCount..<insertedRun.count {
                rows.append(Row(id: rows.count, beforeLine: nil,
                                afterLine: insertedRun[k] + 1, before: nil,
                                after: rightLines[insertedRun[k]], kind: .added,
                                beforeHighlight: nil, afterHighlight: nil,
                                intralineWasLimited: false, isIgnoredBlank: false))
            }
            i += removedRun.count
            j += insertedRun.count
        }
        return rows
    }

    // MARK: - Differenzen-Liste

    /// Fasst aufeinanderfolgende veränderte Zeilen zu Blöcken zusammen —
    /// die Einträge der Differenzen-Liste unter dem Diff (BBEdit-Vorbild).
    static func blocks(for rows: [Row]) -> [Block] {
        var blocks: [Block] = []
        var runStart: Int? = nil

        func flush(upTo end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let run = rows[start..<end]
            let beforeNumbers = run.compactMap(\.beforeLine)
            let afterNumbers = run.compactMap(\.afterLine)
            let kinds = Set(run.map(\.kind))
            let kind: BlockKind
            if kinds == [.added] { kind = .onlyRight }
            else if kinds == [.removed] { kind = .onlyLeft }
            else { kind = .changed }
            blocks.append(Block(
                id: blocks.count,
                firstRowID: rows[start].id,
                lastRowID: rows[end - 1].id,
                kind: kind,
                beforeLines: beforeNumbers.isEmpty
                    ? nil : beforeNumbers.min()!...beforeNumbers.max()!,
                afterLines: afterNumbers.isEmpty
                    ? nil : afterNumbers.min()!...afterNumbers.max()!
            ))
        }

        for (index, row) in rows.enumerated() {
            if row.kind == .unchanged {
                flush(upTo: index)
            } else if runStart == nil {
                runStart = index
            }
        }
        flush(upTo: rows.count)
        return blocks
    }

    // MARK: - Falten unveränderter Bereiche

    /// Sichtbares Element der Diff-Ansicht: echte Zeile oder Falt-Knopf.
    /// Gleiche Mechanik wie `GitDiffVisibleItem` — lange unveränderte Läufe
    /// werden eingeklappt, damit auch große Dateien flüssig rendern.
    enum VisibleItem: Hashable, Identifiable {
        case row(Row)
        case fold(Fold)

        var id: String {
            switch self {
            case .row(let row): return "row-\(row.id)"
            case .fold(let fold): return fold.id
            }
        }
    }

    /// Ein eingeklappter Lauf unveränderter Zeilen.
    struct Fold: Hashable, Identifiable {
        /// Stabil über Neuberechnungen mit gleichem Ergebnis: erste Zeile.
        let id: String
        let count: Int
        /// Row-IDs des eingeklappten Bereichs (halb-offen).
        let rowIDs: Range<Int>
    }

    /// Sichtbare Kontextzeilen an jedem Rand eines unveränderten Laufs.
    static let contextEdge = 3
    /// Erst ab so vielen einklappbaren Zeilen lohnt ein Falt-Knopf.
    static let minimumFoldSize = 5

    /// Berechnet die sichtbaren Elemente: unveränderte Läufe werden bis auf
    /// `contextEdge` Zeilen an den Rändern eingeklappt. Läufe am Datei-
    /// Anfang/-Ende behalten nur den Rand, der an eine Änderung grenzt.
    /// (Identische Dateien rendern gar keine Zeilenliste — die Ansicht zeigt
    /// dann die „Keine Unterschiede"-Meldung und ruft dies nicht auf.)
    static func visibleItems(rows: [Row], expandedFolds: Set<String>) -> [VisibleItem] {
        var result: [VisibleItem] = []
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .unchanged else {
                result.append(.row(rows[index]))
                index += 1
                continue
            }
            // Lauf unveränderter Zeilen [index, runEnd) einsammeln.
            var runEnd = index
            while runEnd < rows.count, rows[runEnd].kind == .unchanged { runEnd += 1 }
            let touchesStart = index == 0
            let touchesEnd = runEnd == rows.count
            // Kontext nur an Rändern, die an eine Änderung grenzen.
            let keepHead = touchesStart ? 0 : contextEdge
            let keepTail = touchesEnd ? 0 : contextEdge
            let foldable = (runEnd - index) - keepHead - keepTail
            if foldable >= minimumFoldSize {
                for k in index..<(index + keepHead) { result.append(.row(rows[k])) }
                let foldStart = index + keepHead
                let foldEnd = runEnd - keepTail
                let fold = Fold(id: "fold-\(rows[foldStart].id)",
                                count: foldEnd - foldStart,
                                rowIDs: rows[foldStart].id..<(rows[foldEnd - 1].id + 1))
                if expandedFolds.contains(fold.id) {
                    for k in foldStart..<foldEnd { result.append(.row(rows[k])) }
                } else {
                    result.append(.fold(fold))
                }
                for k in foldEnd..<runEnd { result.append(.row(rows[k])) }
            } else {
                for k in index..<runEnd { result.append(.row(rows[k])) }
            }
            index = runEnd
        }
        return result
    }
}
