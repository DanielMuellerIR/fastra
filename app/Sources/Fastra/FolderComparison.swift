import Darwin
import Foundation

enum FolderComparison {
    enum Status: String, CaseIterable, Hashable, Sendable {
        case onlyLeft, onlyRight, identical, different, unavailable

        var title: String {
            switch self {
            case .onlyLeft: L10n.string("Nur links")
            case .onlyRight: L10n.string("Nur rechts")
            case .identical: L10n.string("Identisch")
            case .different: L10n.string("Verschieden")
            case .unavailable: L10n.string("Nicht prüfbar")
            }
        }
    }

    struct Options: Hashable, Sendable {
        var knownTextOnly = false
        var excludedPatterns: [String] = []
        var maximumEntries = 20_000
        var maximumVisitedEntries = 100_000
        var maximumDepth = 64
        var maximumFileBytes = FileSnapshot.maximumReadBytes
        var maximumTotalBytes: UInt64 = 2 * 1024 * 1024 * 1024
    }

    struct Progress: Hashable, Sendable {
        enum Phase: Hashable, Sendable { case enumerating, comparing, validating }
        let phase: Phase
        let completed: Int
        let total: Int?
        let budgetBytes: UInt64
    }

    struct Row: Identifiable, Hashable, Sendable {
        // Swift-String-Gleichheit normalisiert Unicode. Dateinamen werden
        // deshalb über ihre tatsächlichen UTF-8-Bytes zugeordnet.
        let id: Data
        let path: String
        let leftURL: URL?
        let rightURL: URL?
        let isDirectory: Bool
        var status: Status
        var detail: String?
        var canOpenPair: Bool {
            !isDirectory && leftURL != nil && rightURL != nil
                && (status == .identical || status == .different)
        }
    }

    struct Result: Hashable, Sendable {
        let rows: [Row]
        let issues: [String]
        let budgetBytes: UInt64
        var isComplete: Bool { issues.isEmpty && !rows.contains { $0.status == .unavailable } }
    }

    private struct Version: Hashable {
        let identity: FileIdentity
        let mode: UInt16
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanos: Int64
        let ctimeSeconds: Int64
        let ctimeNanos: Int64

        init(_ info: stat) {
            identity = FileIdentity(stat: info); mode = info.st_mode
            size = Int64(info.st_size)
            mtimeSeconds = Int64(info.st_mtimespec.tv_sec); mtimeNanos = Int64(info.st_mtimespec.tv_nsec)
            ctimeSeconds = Int64(info.st_ctimespec.tv_sec); ctimeNanos = Int64(info.st_ctimespec.tv_nsec)
        }

        static func read(_ url: URL) -> Self? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return Self(info)
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegular: Bool { mode & S_IFMT == S_IFREG }
    }

    private struct Entry {
        let url: URL
        let path: String
        let version: Version?
        var issue: String?
    }

    private struct Tree {
        let root: URL
        let version: Version?
        var entries: [Data: Entry] = [:]
        var issues: [String] = []
    }

    static func compare(left: URL, right: URL, options: Options = Options(),
                        isCancelled: @escaping () -> Bool = { false },
                        progress: (Progress) -> Void = { _ in }) throws -> Result {
        var lastProgress: TimeInterval = 0
        var budgetBytes: UInt64 = 0
        var totalVisited = 0
        func report(_ phase: Progress.Phase, _ completed: Int, _ total: Int? = nil, force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastProgress >= 0.1 else { return }
            lastProgress = now
            progress(Progress(phase: phase, completed: completed, total: total, budgetBytes: budgetBytes))
        }
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        func scan(_ selectedRoot: URL, side: String) throws -> Tree {
            try checkCancellation()
            guard selectedRoot.isFileURL else {
                return Tree(root: selectedRoot, version: nil,
                    issues: [L10n.format("%@: Es können nur lokale Ordner verglichen werden.", side)])
            }
            let root = selectedRoot.standardizedFileURL.canonicalFileURL
            var tree = Tree(root: root, version: Version.read(root))
            guard tree.version?.isDirectory == true else {
                tree.issues.append(L10n.format("%@: Der Ordner ist nicht verfügbar oder kein Verzeichnis.", side))
                return tree
            }
            let matcher = PathExclusion.Matcher(patterns: options.excludedPatterns, relativeTo: root)
            var enumerationIssues: [String] = []
            var enumerationErrorCount = 0
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles], errorHandler: { url, error in
                    guard !isCancelled() else { return false }
                    enumerationErrorCount += 1
                    if enumerationIssues.count < 10 {
                        enumerationIssues.append(url.lastPathComponent + ": " + error.localizedDescription)
                    }
                    return enumerationErrorCount < max(1, options.maximumVisitedEntries)
                }) else {
                tree.issues.append(L10n.format("%@: Der Ordnerinhalt konnte nicht vollständig gelesen werden.", side))
                return tree
            }
            var visited = 0
            var entryLimitReached = false
            for case let enumeratedURL as URL in enumerator {
                try checkCancellation()
                visited += 1
                totalVisited += 1
                if visited > max(0, options.maximumVisitedEntries) || tree.entries.count >= max(0, options.maximumEntries) {
                    tree.issues.append(L10n.string("Die Grenze für Ordner- und Dateieinträge wurde erreicht."))
                    entryLimitReached = true
                    break
                }
                // Foundation kann beim Enumerieren /private/var liefern,
                // obwohl die Wurzel /var heißt. Die tatsächliche Rekursionstiefe
                // bestimmt den relativen Pfad ohne solche Alias-Präfixe.
                let path = enumeratedURL.pathComponents.suffix(enumerator.level).joined(separator: "/")
                let url = root.appendingPathComponent(path)
                if matcher.matches(url) { enumerator.skipDescendants(); continue }
                let version = Version.read(url)
                if version?.isDirectory != true, options.knownTextOnly,
                   !FolderSearch.passesFilter(url: url, filter: .knownText) { continue }
                var issue: String?
                if enumerator.level > max(0, options.maximumDepth) {
                    issue = L10n.string("Die maximale Ordnertiefe wurde erreicht.")
                    enumerator.skipDescendants()
                } else if version == nil {
                    issue = L10n.string("Der Eintrag konnte nicht gelesen werden.")
                    enumerator.skipDescendants()
                } else if version?.isDirectory != true && version?.isRegular != true {
                    issue = L10n.string("Symlinks und besondere Dateien werden nicht verfolgt oder verglichen.")
                    enumerator.skipDescendants()
                }
                tree.entries[Data(path.utf8)] = Entry(url: url, path: path, version: version, issue: issue)
                report(.enumerating, totalVisited)
            }
            try checkCancellation()
            if !enumerationIssues.isEmpty {
                tree.issues.append(L10n.format("%@: Der Ordnerinhalt konnte nicht vollständig gelesen werden.", side))
                tree.issues.append(contentsOf: enumerationIssues.prefix(10))
            }
            if entryLimitReached || !enumerationIssues.isEmpty {
                // Nach Abbruch oder Rekursionsfehler ist der Inhalt der
                // Struktur nicht vollständig belegt. Keine Ordnerzeile darf
                // dann aus einer leeren Kinderliste „identisch“ ableiten.
                for key in Array(tree.entries.keys) where tree.entries[key]?.version?.isDirectory == true {
                    tree.entries[key]?.issue = tree.issues.first
                }
            }
            return tree
        }
        let lhs = try scan(left, side: L10n.string("Links")), rhs = try scan(right, side: L10n.string("Rechts"))
        let keys = Set(lhs.entries.keys).union(rhs.entries.keys).sorted { $0.lexicographicallyPrecedes($1) }
        var issues = lhs.issues + rhs.issues
        var rows: [Row] = []
        rows.reserveCapacity(keys.count)
        report(.comparing, 0, keys.count, force: true)
        func hasUnverifiedAncestor(_ path: String, in tree: Tree) -> Bool {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if tree.entries[Data(parent.utf8)]?.issue != nil { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        func snapshot(_ entry: Entry, root: URL) throws -> FileSnapshot {
            try checkCancellation()
            guard let version = entry.version, version.isRegular,
                  version == Version.read(entry.url),
                  entry.url.canonicalFileURL.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                throw FileSnapshotReadError.changedDuringRead
            }
            let opened = try FileSnapshot.openRegularFile(at: entry.url)
            defer { close(opened.descriptor) }
            guard Version(opened.stat) == version else { throw FileSnapshotReadError.changedDuringRead }
            guard version.size >= 0, UInt64(version.size) <= options.maximumFileBytes else {
                throw FileSnapshotReadError.tooLarge(byteCount: UInt64(max(0, version.size)))
            }
            guard budgetBytes < options.maximumTotalBytes,
                  UInt64(version.size) <= options.maximumTotalBytes - budgetBytes else {
                throw NSError(domain: "FolderComparison", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("Das Gesamtlesebudget des Ordnervergleichs wurde erreicht.")])
            }
            // Auch ein fehlschlagender Read verbraucht seine tatsächlich
            // gelesenen Bytes. Wachstum darf das Gesamtbudget nicht umgehen.
            defer {
                let consumed = lseek(opened.descriptor, 0, SEEK_CUR)
                if consumed > 0 { budgetBytes += UInt64(consumed) }
            }
            return try FileSnapshot.readSnapshotOnly(descriptor: opened.descriptor, fileStat: opened.stat,
                byteLimit: min(options.maximumFileBytes, UInt64(version.size)), isCancelled: isCancelled)
        }
        for (index, key) in keys.enumerated() {
            try checkCancellation()
            let a = lhs.entries[key], b = rhs.entries[key]
            let entry = a ?? b!
            var row = Row(id: key, path: entry.path, leftURL: a?.url, rightURL: b?.url,
                isDirectory: a?.version?.isDirectory == true || b?.version?.isDirectory == true,
                status: .unavailable, detail: a?.issue ?? b?.issue)
            if row.detail == nil {
                if a == nil || b == nil {
                    if !lhs.issues.isEmpty || !rhs.issues.isEmpty
                        || hasUnverifiedAncestor(entry.path, in: a == nil ? lhs : rhs) {
                        row.detail = L10n.string("Die Gegenseite wurde nicht vollständig gelesen; ein fehlender Eintrag ist nicht sicher belegt.")
                    } else { row.status = a == nil ? .onlyRight : .onlyLeft }
                } else if a!.version?.isDirectory != b!.version?.isDirectory {
                    row.status = .different
                    row.detail = L10n.string("Datei und Ordner stehen am selben relativen Pfad.")
                } else if row.isDirectory { row.status = .identical }
                else {
                    do {
                        let first = try snapshot(a!, root: lhs.root), second = try snapshot(b!, root: rhs.root)
                        row.status = first.hasSameContent(as: second) ? .identical : .different
                    } catch is CancellationError { throw CancellationError() }
                    catch FileSnapshotReadError.tooLarge {
                        row.detail = L10n.string("Die Datei überschreitet die Grenze von 256 MiB je Datei.")
                    } catch FileSnapshotReadError.changedDuringRead {
                        row.detail = L10n.string("Der Eintrag hat sich während der Prüfung geändert. Vergleiche die Ordner erneut.")
                    } catch { row.detail = error.localizedDescription }
                }
            }
            rows.append(row)
            report(.comparing, index + 1, keys.count)
        }
        // Auch ein früh gelesener Eintrag kann sich während späterer Reads
        // ändern. Die abschließende Versionprüfung kennzeichnet diesen Fall.
        report(.validating, 0, rows.count, force: true)
        var directoryChanged = false
        for index in rows.indices {
            try checkCancellation()
            for tree in [lhs, rhs] {
                if let entry = tree.entries[rows[index].id], entry.version != Version.read(entry.url) {
                    if entry.version?.isDirectory == true { directoryChanged = true }
                    rows[index].status = .unavailable
                    rows[index].detail = L10n.string("Der Eintrag hat sich während der Prüfung geändert. Vergleiche die Ordner erneut.")
                }
            }
            report(.validating, index + 1, rows.count)
        }
        let leftRootChanged = lhs.version.map { $0 != Version.read(lhs.root) } ?? false
        let rightRootChanged = rhs.version.map { $0 != Version.read(rhs.root) } ?? false
        if leftRootChanged || rightRootChanged || directoryChanged {
            issues.append(L10n.string("Die Ordnerstruktur hat sich während der Prüfung geändert. Das Ergebnis ist unvollständig."))
            for index in rows.indices where rows[index].status == .onlyLeft || rows[index].status == .onlyRight {
                rows[index].status = .unavailable
                rows[index].detail = issues.last
            }
        }
        // Ordnerstatus aus den bereits geprüften direkten Kindern ableiten.
        // Rückwärts ist jede Unterebene fertig, bevor ihr Elternordner folgt.
        let indexByPath = Dictionary(uniqueKeysWithValues: rows.indices.map { (rows[$0].id, $0) })
        for index in rows.indices.reversed() {
            let parent = (rows[index].path as NSString).deletingLastPathComponent
            guard let parentIndex = indexByPath[Data(parent.utf8)],
                  rows[parentIndex].status == .identical || rows[parentIndex].status == .different else { continue }
            if rows[index].status == .unavailable {
                rows[parentIndex].status = .unavailable
                if rows[parentIndex].detail == nil {
                    rows[parentIndex].detail = rows[index].detail
                        ?? L10n.string("Mindestens ein Untereintrag konnte nicht geprüft werden.")
                }
            }
            else if rows[index].status != .identical { rows[parentIndex].status = .different }
        }
        report(.validating, rows.count, rows.count, force: true)
        return Result(rows: rows, issues: issues, budgetBytes: budgetBytes)
    }
}
