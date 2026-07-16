import Foundation

/// Stabile Identität und Datenquelle eines read-only Git-Diffs. Der
/// Repositorypfad gehört absichtlich zur Identität: Ein verspäteter Refresh aus
/// Projekt A darf niemals einen gleich benannten Tab in Projekt B überschreiben.
struct GitDiffRequest: Hashable, Identifiable {
    enum Source: Hashable {
        case workingTree(path: String?)
        case staged(path: String)
        case unstaged(path: String)
        case untracked(path: String)
        case commit(hash: String, parent: GitDiffParent, path: String)
    }

    let repositoryPath: String
    let source: Source

    var id: String {
        repositoryPath + "\u{0}" + source.stableIdentity
    }

    /// Ein Commit-Diff benennt den Vergleichspartner ausdrücklich. Bei Merges
    /// ist der erste Eltern-Commit daher eine sichtbare Entscheidung und keine
    /// versteckte Git-Heuristik; ein Root-Commit wird gegen den leeren Baum
    /// verglichen.
    var comparisonDescription: String? {
        guard case .commit(_, let parent, _) = source else { return nil }
        switch parent {
        case .emptyTree:
            return L10n.string("Root-Commit gegen leeren Baum")
        case .commit(let hash, let number, let total):
            if total > 1 {
                return L10n.format("Merge-Commit gegen Eltern-Commit %ld von %ld (%@)",
                                   number, total, String(hash.prefix(7)))
            }
            return L10n.format("Commit gegen Eltern-Commit %@", String(hash.prefix(7)))
        }
    }

    /// Ausschließlich stabile, explizite Optionen. `--literal-pathspecs` steht
    /// vor dem Unterbefehl; so bleiben `:(...)`, führende Bindestriche und
    /// Sonderzeichen normale Dateinamen. 24 Kontextzeilen halten getrennte
    /// Änderungen navigierbar und liefern zugleich genug unveränderten Inhalt
    /// zum Auf-/Einklappen; die Prozess-Ausgabe bleibt separat hart begrenzt.
    var arguments: [String] {
        let stable = [
            "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames",
            "--unified=24", "--src-prefix=a/", "--dst-prefix=b/",
        ]
        switch source {
        case .workingTree(let path):
            return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff"] + stable + ["HEAD", "--"]
                + (path.map { [$0] } ?? [])
        case .staged(let path):
            return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff"] + stable + ["--cached", "--", path]
        case .unstaged(let path):
            return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff"] + stable + ["--", path]
        case .untracked(let path):
            return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff"] + stable
                + ["--no-index", "--", "/dev/null", path]
        case .commit(let hash, let parent, let path):
            switch parent {
            case .emptyTree:
                return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff-tree"] + stable
                    + ["--root", "--no-commit-id", "-p", hash, "--", path]
            case .commit(let parentHash, _, _):
                return ["-c", "core.quotePath=false", "--literal-pathspecs", "diff"] + stable
                    + [parentHash, hash, "--", path]
            }
        }
    }

    /// `git diff --no-index` verwendet Exit 1 für „Unterschiede gefunden“.
    /// Diese Semantik gehört zum Request, damit Initial- und Refresh-Lauf
    /// garantiert dieselben Exit-Codes akzeptieren.
    var acceptedExitCodes: Set<Int32> {
        if case .untracked = source { return [0, 1] }
        return [0]
    }

    static let outputLimit = GitOutputLimit(stdoutBytes: 4 * 1024 * 1024,
                                             stderrBytes: 512 * 1024)
}

private extension GitDiffRequest.Source {
    var stableIdentity: String {
        switch self {
        case .workingTree(nil): return "working-all"
        case .workingTree(.some(let path)): return "working-file\u{0}" + path
        case .staged(let path): return "staged\u{0}" + path
        case .unstaged(let path): return "unstaged\u{0}" + path
        case .untracked(let path): return "untracked\u{0}" + path
        case .commit(let hash, let parent, let path):
            let parentIdentity: String
            switch parent {
            case .emptyTree: parentIdentity = "empty"
            case .commit(let hash, let number, let total):
                parentIdentity = "\(number)/\(total)/\(hash)"
            }
            return "commit\u{0}\(hash)\u{0}\(parentIdentity)\u{0}\(path)"
        }
    }
}

enum GitDiffParent: Hashable {
    case emptyTree
    case commit(hash: String, number: Int, total: Int)
}

enum GitDiffLimitation: Hashable {
    case binary(details: String)
    case combinedDiff(unified: String)
    case invalidUTF8
    case outputTruncated(retainedBytes: Int)
    case tooManyLines(limit: Int)
    case lineTooLong(limit: Int)
    case tooManyHunks(limit: Int)
    case malformed(String)

    var title: String {
        switch self {
        case .binary: return L10n.string("Binärdatei")
        case .combinedDiff: return L10n.string("Kombinierter Merge-Diff")
        case .invalidUTF8: return L10n.string("Nicht als UTF-8 darstellbar")
        case .outputTruncated: return L10n.string("Diff ist zu groß")
        case .tooManyLines: return L10n.string("Zu viele Diff-Zeilen")
        case .lineTooLong: return L10n.string("Diff-Zeile ist zu lang")
        case .tooManyHunks: return L10n.string("Zu viele Änderungsblöcke")
        case .malformed: return L10n.string("Diff konnte nicht gelesen werden")
        }
    }

    var explanation: String {
        switch self {
        case .binary(let details):
            return details.isEmpty
                ? L10n.string("Git meldet binäre Inhalte. Fastra zeigt dafür keinen irreführenden Text-Diff.")
                : details
        case .combinedDiff:
            return L10n.string("Git liefert einen kombinierten Merge- oder Konflikt-Diff. Die zweispaltige Ansicht unterstützt diese Mehr-Eltern-Form noch nicht; die vollständige Unified-Ausgabe steht unten auswählbar bereit.")
        case .invalidUTF8:
            return L10n.string("Die Git-Ausgabe enthält ungültiges UTF-8. Fastra ersetzt keine Bytes und zeigt deshalb keinen möglicherweise verfälschten Text-Diff.")
        case .outputTruncated(let retainedBytes):
            return L10n.format("Der Diff überschreitet die sichere Anzeigegrenze. %lld Bytes wurden geprüft; die Datei bleibt unverändert.", Int64(retainedBytes))
        case .tooManyLines(let limit):
            return L10n.format("Der Diff enthält mehr als %ld Zeilen. Fastra lädt ihn nicht vollständig in die Ansicht.", limit)
        case .lineTooLong(let limit):
            return L10n.format("Mindestens eine Diff-Zeile überschreitet die sichere Grenze von %ld Bytes. Fastra baut dafür keine große Textzeile auf.", limit)
        case .tooManyHunks(let limit):
            return L10n.format("Der Diff enthält mehr als %ld Änderungsblöcke. Fastra begrenzt die Darstellung, statt tausende UI-Elemente anzulegen.", limit)
        case .malformed(let details):
            return details
        }
    }
}

struct GitDiffDocument: Hashable {
    var files: [GitDiffFile]
    var limitation: GitDiffLimitation?
    var isEmpty: Bool { files.isEmpty && limitation == nil }
    var hunks: [GitDiffHunk] { files.flatMap(\.hunks) }
}

struct GitDiffFile: Hashable, Identifiable {
    let id: String
    let oldPath: String?
    let newPath: String?
    let metadata: [String]
    let hunks: [GitDiffHunk]
    let limitation: GitDiffLimitation?
}

struct GitDiffHunk: Hashable, Identifiable {
    let id: String
    let header: String
    let oldStart: Int
    let newStart: Int
    let rows: [GitDiffAlignedRow]
}

enum GitDiffRowKind: Hashable {
    case context, added, removed, changed
}

struct GitDiffAlignedRow: Hashable, Identifiable {
    let id: String
    let hunkID: String
    let kind: GitDiffRowKind
    let beforeNumber: Int?
    let afterNumber: Int?
    let before: String?
    let after: String?
    let beforeHighlight: Range<Int>?
    let afterHighlight: Range<Int>?
    let beforeMissingFinalNewline: Bool
    let afterMissingFinalNewline: Bool
    let intralineWasLimited: Bool
}

/// Eine sichtbare Zeile oder ein zusammengefalteter unveränderter Bereich.
enum GitDiffVisibleItem: Hashable, Identifiable {
    case row(GitDiffAlignedRow)
    case fold(GitDiffFold)

    var id: String {
        switch self {
        case .row(let row): return row.id
        case .fold(let fold): return fold.id
        }
    }
}

struct GitDiffFold: Hashable, Identifiable {
    let id: String
    let hunkID: String
    let rows: [GitDiffAlignedRow]
    var count: Int { rows.count }
}

enum GitDiffParser {
    static let maximumLines = 50_000
    static let maximumLineBytes = 128 * 1024
    static let maximumHunks = 2_000
    static let maximumIntralineCharacters = 4_096

    static func parse(_ data: Data, wasTruncated: Bool = false,
                      maximumLines: Int = maximumLines) -> GitDiffDocument {
        if wasTruncated {
            return GitDiffDocument(files: [], limitation: .outputTruncated(retainedBytes: data.count))
        }
        guard maximumByteLineLength(in: data) <= maximumLineBytes else {
            return GitDiffDocument(files: [], limitation: .lineTooLong(limit: maximumLineBytes))
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            return GitDiffDocument(files: [], limitation: .invalidUTF8)
        }
        // Git selbst trennt Patch-Datensätze mit LF. Ein CR unmittelbar vor
        // diesem LF kann dagegen zum Dateiinhalt gehören (CRLF-Datei) und darf
        // nicht global weg-normalisiert werden.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count <= maximumLines else {
            return GitDiffDocument(files: [], limitation: .tooManyLines(limit: maximumLines))
        }
        if lines.contains(where: {
            $0.hasPrefix("diff --cc ") || $0.hasPrefix("diff --combined ")
                || $0.hasPrefix("@@@ ")
        }) {
            return GitDiffDocument(files: [], limitation: .combinedDiff(unified: raw))
        }
        var files: [GitDiffFile] = []
        var fileMetadata: [String] = []
        var oldPath: String?
        var newPath: String?
        var hunks: [GitDiffHunk] = []
        var fileLimitation: GitDiffLimitation?
        var index = 0
        var fileSequence = 0

        func appendFile() {
            guard !fileMetadata.isEmpty || !hunks.isEmpty || oldPath != nil || newPath != nil else {
                return
            }
            let identity = "file-\(fileSequence)-\(newPath ?? oldPath ?? "unknown")"
            files.append(GitDiffFile(id: identity, oldPath: oldPath, newPath: newPath,
                                     metadata: fileMetadata, hunks: hunks,
                                     limitation: fileLimitation))
            fileSequence += 1
            fileMetadata = []
            oldPath = nil
            newPath = nil
            hunks = []
            fileLimitation = nil
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                appendFile()
                fileMetadata.append(line)
                index += 1
                continue
            }
            if line.hasPrefix("--- ") {
                oldPath = displayPath(String(line.dropFirst(4)))
                fileMetadata.append(line)
                index += 1
                continue
            }
            if line.hasPrefix("+++ ") {
                newPath = displayPath(String(line.dropFirst(4)))
                fileMetadata.append(line)
                index += 1
                continue
            }
            if line.hasPrefix("rename from ") {
                oldPath = String(line.dropFirst("rename from ".count))
                fileMetadata.append(line)
                index += 1
                continue
            }
            if line.hasPrefix("rename to ") {
                newPath = String(line.dropFirst("rename to ".count))
                fileMetadata.append(line)
                index += 1
                continue
            }
            if let coordinates = parseHunkHeader(line) {
                guard hunks.count < maximumHunks,
                      files.lazy.map(\.hunks.count).reduce(0, +) + hunks.count < maximumHunks
                else {
                    return GitDiffDocument(files: [],
                                           limitation: .tooManyHunks(limit: maximumHunks))
                }
                let hunkID = "file-\(fileSequence)-hunk-\(hunks.count)-\(coordinates.oldStart)-\(coordinates.newStart)"
                index += 1
                var body: [String] = []
                while index < lines.count,
                      !lines[index].hasPrefix("@@ "),
                      !lines[index].hasPrefix("diff --git ") {
                    body.append(lines[index])
                    index += 1
                }
                hunks.append(GitDiffHunk(
                    id: hunkID, header: line,
                    oldStart: coordinates.oldStart, newStart: coordinates.newStart,
                    rows: align(body, hunkID: hunkID, oldStart: coordinates.oldStart,
                                newStart: coordinates.newStart)
                ))
                continue
            }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                let details = (fileMetadata.filter(Self.isMetadata) + [line])
                    .joined(separator: "\n")
                fileLimitation = .binary(details: details)
                index += 1
                // Ein möglicher `GIT binary patch`-Payload ist für die
                // read-only Textansicht weder nötig noch sicher hilfreich.
                while index < lines.count, !lines[index].hasPrefix("diff --git ") {
                    index += 1
                }
                continue
            }
            if !line.isEmpty { fileMetadata.append(line) }
            index += 1
        }
        appendFile()
        return GitDiffDocument(files: files, limitation: nil)
    }

    private static func isMetadata(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("index ")
            || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ")
            || line.hasPrefix("similarity index ") || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
    }

    private static func displayPath(_ raw: String) -> String? {
        let path = strippingTerminalTimestamp(from: raw)
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// No-index-Patches können hinter dem Pfad einen TAB plus Dateizeit tragen.
    /// Nur dieses streng validierte terminale Feld wird entfernt; echte Tabs im
    /// Dateinamen bleiben unangetastet.
    static func strippingTerminalTimestamp(from raw: String) -> String {
        guard let tab = raw.lastIndex(of: "\t") else { return raw }
        let suffix = String(raw[raw.index(after: tab)...])
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? [+-]\d{4}$"#
        guard suffix.range(of: pattern, options: .regularExpression) != nil else { return raw }
        return String(raw[..<tab])
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        guard line.hasPrefix("@@ "),
              let closing = line.dropFirst(3).range(of: " @@") else { return nil }
        let coordinates = line[line.index(line.startIndex, offsetBy: 3)..<closing.lowerBound]
        let fields = coordinates.split(separator: " ")
        guard fields.count >= 2,
              let old = rangeStart(fields[0], prefix: "-"),
              let new = rangeStart(fields[1], prefix: "+") else { return nil }
        return (old, new)
    }

    private static func rangeStart(_ value: Substring, prefix: Character) -> Int? {
        guard value.first == prefix else { return nil }
        return Int(value.dropFirst().split(separator: ",", maxSplits: 1)[0])
    }

    private struct RawLine {
        let kind: GitDiffRowKind
        let text: String
        var beforeMissingFinalNewline: Bool = false
        var afterMissingFinalNewline: Bool = false
    }

    private static func align(_ body: [String], hunkID: String,
                              oldStart: Int, newStart: Int) -> [GitDiffAlignedRow] {
        var oldLine = oldStart
        var newLine = newStart
        var output: [GitDiffAlignedRow] = []
        var sequence = 0
        var pendingRemoved: [(RawLine, Int)] = []
        var pendingAdded: [(RawLine, Int)] = []

        func makeID() -> String { defer { sequence += 1 }; return "\(hunkID)-row-\(sequence)" }
        func flushChanges() {
            let paired = min(pendingRemoved.count, pendingAdded.count)
            for position in 0..<paired {
                let before = pendingRemoved[position]
                let after = pendingAdded[position]
                let highlights = intraline(before.0.text, after.0.text)
                output.append(GitDiffAlignedRow(
                    id: makeID(), hunkID: hunkID, kind: .changed,
                    beforeNumber: before.1, afterNumber: after.1,
                    before: before.0.text, after: after.0.text,
                    beforeHighlight: highlights.before, afterHighlight: highlights.after,
                    beforeMissingFinalNewline: before.0.beforeMissingFinalNewline,
                    afterMissingFinalNewline: after.0.afterMissingFinalNewline,
                    intralineWasLimited: highlights.wasLimited
                ))
            }
            if pendingRemoved.count > paired {
                for item in pendingRemoved.dropFirst(paired) {
                    output.append(GitDiffAlignedRow(
                        id: makeID(), hunkID: hunkID, kind: .removed,
                        beforeNumber: item.1, afterNumber: nil,
                        before: item.0.text, after: nil,
                        beforeHighlight: nil, afterHighlight: nil,
                        beforeMissingFinalNewline: item.0.beforeMissingFinalNewline,
                        afterMissingFinalNewline: false,
                        intralineWasLimited: false
                    ))
                }
            }
            if pendingAdded.count > paired {
                for item in pendingAdded.dropFirst(paired) {
                    output.append(GitDiffAlignedRow(
                        id: makeID(), hunkID: hunkID, kind: .added,
                        beforeNumber: nil, afterNumber: item.1,
                        before: nil, after: item.0.text,
                        beforeHighlight: nil, afterHighlight: nil,
                        beforeMissingFinalNewline: false,
                        afterMissingFinalNewline: item.0.afterMissingFinalNewline,
                        intralineWasLimited: false
                    ))
                }
            }
            pendingRemoved.removeAll(keepingCapacity: true)
            pendingAdded.removeAll(keepingCapacity: true)
        }

        var rawLines: [RawLine] = []
        for line in body {
            if line == "\\ No newline at end of file" {
                guard !rawLines.isEmpty else { continue }
                let last = rawLines.removeLast()
                rawLines.append(RawLine(
                    kind: last.kind, text: last.text,
                    beforeMissingFinalNewline: last.beforeMissingFinalNewline
                        || last.kind == .removed || last.kind == .context,
                    afterMissingFinalNewline: last.afterMissingFinalNewline
                        || last.kind == .added || last.kind == .context
                ))
                continue
            }
            guard let prefix = line.first else { continue }
            let rawText = String(line.dropFirst())
            // Ein sichtbares Symbol verhindert, dass reine LF↔CRLF-Änderungen
            // wie identische Zeilen aussehen.
            let text = rawText.hasSuffix("\r")
                ? String(rawText.dropLast()) + "␍" : rawText
            switch prefix {
            case " ": rawLines.append(RawLine(kind: .context, text: text))
            case "-": rawLines.append(RawLine(kind: .removed, text: text))
            case "+": rawLines.append(RawLine(kind: .added, text: text))
            default: break
            }
        }

        for line in rawLines {
            switch line.kind {
            case .context:
                flushChanges()
                output.append(GitDiffAlignedRow(
                    id: makeID(), hunkID: hunkID, kind: .context,
                    beforeNumber: oldLine, afterNumber: newLine,
                    before: line.text, after: line.text,
                    beforeHighlight: nil, afterHighlight: nil,
                    beforeMissingFinalNewline: line.beforeMissingFinalNewline,
                    afterMissingFinalNewline: line.afterMissingFinalNewline,
                    intralineWasLimited: false
                ))
                oldLine += 1
                newLine += 1
            case .removed: pendingRemoved.append((line, oldLine)); oldLine += 1
            case .added: pendingAdded.append((line, newLine)); newLine += 1
            default: break
            }
        }
        flushChanges()
        return output
    }

    /// Linear und bewusst klein: gemeinsamer Präfix und Suffix. Bereiche sind
    /// Zeichen-Offsets (nicht UTF-16), weil SwiftUI `AttributedString` daraus
    /// direkt sichere String-Indizes bilden kann.
    static func intraline(_ before: String, _ after: String)
        -> (before: Range<Int>?, after: Range<Int>?, wasLimited: Bool) {
        guard before.count <= maximumIntralineCharacters,
              after.count <= maximumIntralineCharacters else {
            return (nil, nil, true)
        }
        let a = Array(before)
        let b = Array(after)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let aEnd = a.count - suffix
        let bEnd = b.count - suffix
        return (prefix < aEnd ? prefix..<aEnd : nil,
                prefix < bEnd ? prefix..<bEnd : nil, false)
    }

    private static func maximumByteLineLength(in data: Data) -> Int {
        var current = 0
        var maximum = 0
        for byte in data {
            if byte == 0x0a { maximum = max(maximum, current); current = 0 }
            else { current += 1 }
        }
        return max(maximum, current)
    }
}

/// Pure UI-Modellfunktionen: Falten, Hunk-Navigation und Ruler-Positionen.
enum GitDiffViewModel {
    static let contextEdge = 3

    static func visibleItems(document: GitDiffDocument,
                             expandedFolds: Set<String>) -> [GitDiffVisibleItem] {
        document.hunks.flatMap { visibleItems(hunk: $0, expandedFolds: expandedFolds) }
    }

    static func visibleItems(hunk: GitDiffHunk,
                             expandedFolds: Set<String>) -> [GitDiffVisibleItem] {
        fold(rows: hunk.rows, hunkID: hunk.id, expandedFolds: expandedFolds)
    }

    private static func fold(rows: [GitDiffAlignedRow], hunkID: String,
                             expandedFolds: Set<String>) -> [GitDiffVisibleItem] {
        var result: [GitDiffVisibleItem] = []
        var index = 0
        var foldSequence = 0
        while index < rows.count {
            guard rows[index].kind == .context else {
                result.append(.row(rows[index])); index += 1; continue
            }
            let start = index
            while index < rows.count, rows[index].kind == .context { index += 1 }
            let block = Array(rows[start..<index])
            guard block.count > contextEdge * 2 + 1 else {
                result.append(contentsOf: block.map(GitDiffVisibleItem.row)); continue
            }
            result.append(contentsOf: block.prefix(contextEdge).map(GitDiffVisibleItem.row))
            let hidden = Array(block.dropFirst(contextEdge).dropLast(contextEdge))
            let fold = GitDiffFold(id: "\(hunkID)-fold-\(foldSequence)",
                                   hunkID: hunkID, rows: hidden)
            foldSequence += 1
            if expandedFolds.contains(fold.id) {
                result.append(.fold(fold))
                result.append(contentsOf: hidden.map(GitDiffVisibleItem.row))
            } else {
                result.append(.fold(fold))
            }
            result.append(contentsOf: block.suffix(contextEdge).map(GitDiffVisibleItem.row))
        }
        return result
    }

    static func adjacentHunk(current: Int?, count: Int, direction: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return direction >= 0 ? 0 : count - 1 }
        return min(max(current + direction, 0), count - 1)
    }

    static func reconciledHunkIndex(previousID: String?, previousIndex: Int?,
                                    hunks: [GitDiffHunk]) -> Int? {
        guard !hunks.isEmpty else { return nil }
        if let previousID,
           let exact = hunks.firstIndex(where: { $0.id == previousID }) { return exact }
        return min(max(previousIndex ?? 0, 0), hunks.count - 1)
    }

    static func currentHunkIndex(positions: [String: Double], orderedIDs: [String],
                                 viewportTop: Double = 0) -> Int? {
        guard !orderedIDs.isEmpty else { return nil }
        let visible = orderedIDs.enumerated().compactMap { index, id in
            positions[id].map { (index, $0) }
        }
        guard !visible.isEmpty else { return nil }
        // Der letzte bereits an der Oberkante vorbeigelaufene Header ist der
        // aktuelle Block; liegt noch keiner darüber, zählt der nächste sichtbare.
        if let passed = visible.filter({ $0.1 <= viewportTop }).max(by: { $0.1 < $1.1 }) {
            return passed.0
        }
        return visible.min(by: { abs($0.1 - viewportTop) < abs($1.1 - viewportTop) })?.0
    }

    static func validExpandedFolds(_ expanded: Set<String>,
                                   document: GitDiffDocument) -> Set<String> {
        var valid: Set<String> = []
        for hunk in document.hunks {
            for item in visibleItems(hunk: hunk, expandedFolds: []) {
                if case .fold(let fold) = item { valid.insert(fold.id) }
            }
        }
        return expanded.intersection(valid)
    }

    static func rulerPositions(hunkCount: Int) -> [Double] {
        guard hunkCount > 0 else { return [] }
        if hunkCount == 1 { return [0.5] }
        return (0..<hunkCount).map { Double($0) / Double(hunkCount - 1) }
    }


    static func rulerMarkerIndices(hunkCount: Int, currentHunk: Int? = nil,
                                   maximumMarkers: Int = 160) -> [Int] {
        guard hunkCount > 0, maximumMarkers > 0 else { return [] }
        guard hunkCount > maximumMarkers else { return Array(0..<hunkCount) }
        guard maximumMarkers > 1 else {
            return [min(max(currentHunk ?? 0, 0), hunkCount - 1)]
        }
        var indices = (0..<maximumMarkers).map {
            Int((Double($0) * Double(hunkCount - 1) / Double(maximumMarkers - 1)).rounded())
        }
        guard let currentHunk, (0..<hunkCount).contains(currentHunk),
              !indices.contains(currentHunk) else { return indices }

        // Der aktuelle Block muss auch bei stark heruntergerechneten Diffs eine
        // echte, anklickbare Markierung besitzen. Dafür ersetzen wir den
        // nächstgelegenen inneren Sampling-Punkt und behalten die Randmarker.
        let inner = indices.indices.dropFirst().dropLast()
        let replacement = inner.min {
            abs(indices[$0] - currentHunk) < abs(indices[$1] - currentHunk)
        } ?? indices.indices.min {
            abs(indices[$0] - currentHunk) < abs(indices[$1] - currentHunk)
        }!
        indices[replacement] = currentHunk
        return indices.sorted()
    }

    /// Anzahl der von Git zwischen zwei Hunk-Kontexten ausgelassenen
    /// unveränderten Zeilen. `previous == nil` beschreibt den Dateianfang.
    static func omittedLineCount(previous: GitDiffHunk?, current: GitDiffHunk) -> Int {
        guard let previous else {
            return max(0, max(current.oldStart - 1, current.newStart - 1))
        }
        let oldLength = previous.rows.lazy.filter { $0.beforeNumber != nil }.count
        let newLength = previous.rows.lazy.filter { $0.afterNumber != nil }.count
        let oldGap = current.oldStart - (previous.oldStart + oldLength)
        let newGap = current.newStart - (previous.newStart + newLength)
        return max(0, max(oldGap, newGap))
    }
}

// MARK: - Kompatibler Unified-Fallback für Verlauf und Commit-Metadaten

enum GitDiffLineKind: Equatable {
    case added, removed, hunk, fileHeader, commitMeta, context
}

enum GitDiff {
    static let arguments = GitDiffRequest(
        repositoryPath: "", source: .workingTree(path: nil)
    ).arguments

    static func showArguments(hash: String) -> [String] {
        ["show", "--no-color", "--no-ext-diff", "--no-textconv", "--stat", "--patch", hash]
    }

    static func stagedFileArguments(path: String) -> [String] {
        GitDiffRequest(repositoryPath: "", source: .staged(path: path)).arguments
    }

    static func unstagedFileArguments(path: String) -> [String] {
        GitDiffRequest(repositoryPath: "", source: .unstaged(path: path)).arguments
    }

    static func untrackedFileArguments(path: String) -> [String] {
        GitDiffRequest(repositoryPath: "", source: .untracked(path: path)).arguments
    }

    static func showFileArguments(hash: String, path: String) -> [String] {
        ["-c", "core.quotePath=false", "--literal-pathspecs", "show", "--no-color",
         "--no-ext-diff", "--no-textconv", "--format=", hash, "--", path]
    }

    static func classify(_ line: String) -> GitDiffLineKind {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ") { return .fileHeader }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("commit ") || line.hasPrefix("Author:")
            || line.hasPrefix("Date:") || line.hasPrefix("Merge:") { return .commitMeta }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
